#!/usr/bin/env bash
# Build locally first; publishing is a separate step after smoke tests and scans.
set -euo pipefail
cd "$(dirname "$0")/.."

registry=${REGISTRY:-ghcr.io/jaredpricedev/ingress-nginx}
tag=${PATCHED_TAG:-v1.12.3-patch.20261029}
arch=${ARCH:-amd64}
if [[ "$arch" != amd64 || $(uname -m) != x86_64 ]]; then
  echo 'This workflow currently validates native linux/amd64 only.' >&2
  exit 1
fi
mkdir -p dist/patched-images
base="$registry/nginx:$tag"

docker build --pull --no-cache -t "$base" images/nginx/rootfs
export PKG=k8s.io/ingress-nginx ARCH="$arch" GOOS=linux
export COMMIT_SHA="$(git rev-parse HEAD)" REPO_INFO="https://github.com/jaredpricedev/ingress-nginx"
export TAG="$tag"
bash build/build.sh

for variant in controller controller-chroot; do
  dockerfile=rootfs/Dockerfile
  [[ "$variant" != controller-chroot ]] || dockerfile=rootfs/Dockerfile-chroot
  docker build --no-cache -f "$dockerfile" \
    --build-arg BASE_IMAGE="$base" --build-arg TARGETARCH="$arch" \
    --build-arg VERSION="$tag" --build-arg COMMIT_SHA="$COMMIT_SHA" \
    --build-arg BUILD_ID="${GITHUB_RUN_ID:-local}" \
    -t "$registry/$variant:$tag" rootfs
done
for helper in kube-webhook-certgen custom-error-pages; do
  docker build --pull --no-cache --build-arg GOLANG_VERSION="$(cat GOLANG_VERSION)" \
    -t "$registry/$helper:$tag" "images/$helper/rootfs"
done
for image in nginx controller controller-chroot kube-webhook-certgen custom-error-pages; do
  printf '%s/%s:%s\n' "$registry" "$image" "$tag"
done > dist/patched-images/images.txt
bash hack/smoke-patched-images.sh
