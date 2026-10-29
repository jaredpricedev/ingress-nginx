#!/usr/bin/env bash
# Install the original 4.12.3 release, then upgrade only its container inputs.
set -euo pipefail
cd "$(dirname "$0")/.."
registry=${REGISTRY:-ghcr.io/jaredpricedev/ingress-nginx}
tag=${PATCHED_TAG:?PATCHED_TAG is required}
cluster=ingress-compat
logs=dist/patched-images/compatibility
mkdir -p "$logs"
cleanup() {
  [[ -z ${forward_pid:-} ]] || kill "$forward_pid" 2>/dev/null || true
  kind export logs "$logs/kind" --name "$cluster" || true
  kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller --tail=500 > "$logs/controller.log" 2>&1 || true
  kind delete cluster --name "$cluster"
}
trap cleanup EXIT
# Use the kind release and immutable node image published together upstream.
case "${K8S_VERSION:-v1.32.5}" in
  v1.28.15)
    kind_version=v0.25.0
    node_image=kindest/node:v1.28.15@sha256:a7c05c7ae043a0b8c818f5a06188bc2c4098f6cb59ca7d1856df00375d839251
    ;;
  v1.32.5)
    kind_version=v0.28.0
    node_image=kindest/node:v1.32.5@sha256:36187f6c542fa9b78d2d499de4c857249c5a0ac8cc2241bef2ccd92729a7a259
    ;;
  *) echo 'This fixture supports Kubernetes v1.28.15 and v1.32.5.' >&2; exit 1 ;;
esac
go install "sigs.k8s.io/kind@$kind_version"
kind create cluster --name "$cluster" --image="$node_image"
kind load docker-image --name "$cluster" "$registry/controller:$tag" "$registry/controller-chroot:$tag" "$registry/kube-webhook-certgen:$tag" "$registry/custom-error-pages:$tag"
helm upgrade --install ingress-nginx ./charts/ingress-nginx --namespace ingress-nginx --create-namespace --wait --timeout 5m
cat > "$logs/routes.yaml" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: compatibility-backend
  namespace: ingress-nginx
spec:
  selector:
    app: compatibility-backend
  ports:
    - port: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: compatibility
  namespace: ingress-nginx
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [compat.test]
      secretName: compatibility-tls
  rules:
    - host: compat.test
      http:
        paths:
          - path: /healthz
            pathType: Prefix
            backend:
              service:
                name: compatibility-backend
                port:
                  number: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: compatibility-rewrite
  namespace: ingress-nginx
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
    - host: rewrite.test
      http:
        paths:
          - path: /rewrite(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: compatibility-backend
                port:
                  number: 8080
YAML
kubectl -n ingress-nginx create deployment compatibility-backend --image="$registry/custom-error-pages:$tag"
kubectl -n ingress-nginx patch deployment compatibility-backend --type=merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"custom-error-pages","image":"'"$registry/custom-error-pages:$tag"'","imagePullPolicy":"Never"}]}}}}'
kubectl -n ingress-nginx rollout status deployment/compatibility-backend --timeout=3m
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$logs/tls.key" -out "$logs/tls.crt" -subj /CN=compat.test -addext subjectAltName=DNS:compat.test
kubectl -n ingress-nginx create secret tls compatibility-tls --cert="$logs/tls.crt" --key="$logs/tls.key"
rm "$logs/tls.key"
kubectl apply -f "$logs/routes.yaml"
probe() {
  kubectl -n ingress-nginx port-forward service/ingress-nginx-controller 18080:80 18443:443 > "$logs/port-forward.log" 2>&1 &
  forward_pid=$!
  curl --fail --silent --show-error --retry 30 --retry-all-errors --retry-delay 2 -H 'Host: compat.test' http://127.0.0.1:18080/healthz
  curl --fail --silent --show-error --retry 10 --retry-all-errors --retry-delay 2 -H 'Host: rewrite.test' http://127.0.0.1:18080/rewrite/healthz
  curl --fail --silent --show-error --retry 10 --retry-all-errors --retry-delay 2 --noproxy '*' --resolve compat.test:18443:127.0.0.1 --cacert "$logs/tls.crt" https://compat.test:18443/healthz
  kill "$forward_pid"
  wait "$forward_pid" 2>/dev/null || true
  forward_pid=
}
probe
helm upgrade ingress-nginx ./charts/ingress-nginx --namespace ingress-nginx --reuse-values --wait --timeout 5m \
  --set controller.image.registry="${registry%%/*}" \
  --set controller.image.image="${registry#*/}/controller" \
  --set controller.image.tag="$tag" --set controller.image.digest= --set controller.image.digestChroot= \
  --set controller.image.pullPolicy=Never \
  --set controller.admissionWebhooks.patch.image.registry="${registry%%/*}" \
  --set controller.admissionWebhooks.patch.image.image="${registry#*/}/kube-webhook-certgen" \
  --set controller.admissionWebhooks.patch.image.tag="$tag" \
  --set controller.admissionWebhooks.patch.image.digest= --set controller.admissionWebhooks.patch.image.pullPolicy=Never
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=3m
probe
# New Ingress admission must work as well as updates after the UID validation fix.
kubectl -n ingress-nginx create ingress compatibility-new --class=nginx --rule="new.test/healthz=compatibility-backend:8080"
# Updating an existing Ingress also verifies the patched admission webhook works.
kubectl -n ingress-nginx annotate ingress compatibility nginx.ingress.kubernetes.io/proxy-read-timeout=61
probe
helm get values ingress-nginx -n ingress-nginx --all > "$logs/values.yaml"
kubectl -n ingress-nginx get deployments,pods,ingresses -o wide > "$logs/resources.txt"
echo 'Chart 4.12.3 upgrade, HTTP, TLS, regex rewrite and admission checks passed.'
