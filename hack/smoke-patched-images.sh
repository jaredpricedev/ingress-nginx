#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
registry=${REGISTRY:-ghcr.io/jaredpricedev/ingress-nginx}
tag=${PATCHED_TAG:-v1.12.3-patch.20261029}
controller="$registry/controller:$tag"

docker run --rm "$controller" /nginx-ingress-controller --version
docker run --rm "$registry/kube-webhook-certgen:$tag" --help
docker run --rm --user 0 --cap-add SYS_CHROOT --cap-add SYS_ADMIN --entrypoint /usr/bin/nginx \
  "$registry/controller-chroot:$tag" -v
docker run --rm --entrypoint nginx "$controller" -v 2>&1 | grep -F 'nginx/1.30.6'

# Exercise Lua plus variable-based set_escape_uri: NDK needs an extra opcode
# after the rewrite-engine security fixes in NGINX 1.30.4+.
config=$(mktemp)
name="patched-ingress-smoke-${RANDOM}"
backend="patched-backend-smoke-${RANDOM}"
cleanup() {
  docker inspect "$name" > dist/patched-images/smoke-container.json 2>&1 || true
  docker logs "$name" > dist/patched-images/smoke-nginx.log 2>&1 || true
  docker logs "$backend" > dist/patched-images/smoke-backend.log 2>&1 || true
  docker rm -f "$name" "$backend" >/dev/null 2>&1 || true
  rm -f "$config"
}
trap cleanup EXIT
cat > "$config" <<'NGINX'
load_module /etc/nginx/modules/ngx_http_modsecurity_module.so;
load_module /etc/nginx/modules/otel_ngx_module.so;
pid /tmp/nginx.pid;
error_log stderr notice;
events { worker_connections 128; }
http {
  access_log off;
  server {
    listen 18080;
    opentelemetry off;
    set $source "hello world";
    set_escape_uri $escaped $source;
    location = /rewrite { return 200 "$escaped"; }
    location = /lua { content_by_lua_block { ngx.say("lua-ok") } }
    location = /substitution {
      subs_filter_types *;
      subs_filter old-content new-content;
      content_by_lua_block { ngx.say("old-content") }
    }
    location = /waf {
      modsecurity on;
      # Put enforcing settings first: rule-set merges preserve the first value.
      modsecurity_rules '
        SecRuleEngine On
        SecAuditEngine Off
        SecRule ARGS:block "@streq yes" "id:1000,phase:1,deny,status:403,nolog"
      ';
      modsecurity_rules_file /etc/nginx/modsecurity/modsecurity.conf;
      modsecurity_rules_file /etc/nginx/owasp-modsecurity-crs/nginx-modsecurity.conf;
      content_by_lua_block { ngx.say("waf-ok") }
    }
  }
}
NGINX
chmod 644 "$config"
docker run -d --name "$name" -p 127.0.0.1::18080 \
  -v "$config:/tmp/smoke.conf:ro" --entrypoint nginx "$controller" \
  -c /tmp/smoke.conf -g 'daemon off;'
docker port "$name"
port=$(docker port "$name" 18080/tcp | cut -d: -f2)
curl --fail --silent --show-error --max-time 10 --retry 10 --retry-all-errors --retry-delay 1 \
  "http://127.0.0.1:$port/rewrite" | tee dist/patched-images/smoke-rewrite.txt | grep -Fx 'hello%20world'
curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:$port/lua" | tee dist/patched-images/smoke-lua.txt | grep -Fx 'lua-ok'
curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:$port/substitution" | tee dist/patched-images/smoke-substitution.txt | grep -Fx 'new-content'
curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:$port/waf" | tee dist/patched-images/smoke-waf.txt | grep -Fx 'waf-ok'
curl --silent --output /dev/null --write-out '%{http_code}\n' \
  "http://127.0.0.1:$port/waf?block=yes" | grep -Fx '403'

docker run -d --name "$backend" -p 127.0.0.1::8080 "$registry/custom-error-pages:$tag"
port=$(docker port "$backend" 8080/tcp | cut -d: -f2)
curl --fail --silent --show-error --max-time 10 --retry 10 --retry-all-errors --retry-delay 1 \
  "http://127.0.0.1:$port/healthz"
echo 'Image version, Lua, substitutions, NDK rewrite, ModSecurity/CRS, tracing module load, chroot, certgen and backend smoke checks passed.'
