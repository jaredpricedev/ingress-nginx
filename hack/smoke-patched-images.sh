#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
registry=${REGISTRY:-ghcr.io/jaredpricedev/ingress-nginx}
tag=${PATCHED_TAG:-v1.12.3-patch.20261029}
controller="$registry/controller:$tag"

docker run --rm "$controller" --version
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
  docker rm -f "$name" "$backend" >/dev/null 2>&1 || true
  rm -f "$config"
}
trap cleanup EXIT
cat > "$config" <<'NGINX'
pid /tmp/nginx.pid;
error_log /dev/stderr notice;
events { worker_connections 128; }
http {
  access_log off;
  server {
    listen 18080;
    set $source "hello world";
    set_escape_uri $escaped $source;
    location = /rewrite { return 200 "$escaped"; }
    location = /lua { content_by_lua_block { ngx.say("lua-ok") } }
    location = /substitution {
      subs_filter_types *;
      subs_filter old-content new-content;
      content_by_lua_block { ngx.say("old-content") }
    }
  }
}
NGINX
chmod 644 "$config"
docker run -d --name "$name" -p 127.0.0.1::18080 \
  -v "$config:/tmp/smoke.conf:ro" --entrypoint nginx "$controller" \
  -c /tmp/smoke.conf -g 'daemon off;'
port=$(docker port "$name" 18080/tcp | cut -d: -f2)
curl --fail --silent --retry 10 --retry-connrefused --retry-delay 1 \
  "http://127.0.0.1:$port/rewrite" | grep -Fx 'hello%20world'
curl --fail --silent "http://127.0.0.1:$port/lua" | grep -Fx 'lua-ok'

docker run -d --name "$backend" -p 127.0.0.1::8080 "$registry/custom-error-pages:$tag"
port=$(docker port "$backend" 8080/tcp | cut -d: -f2)
curl --fail --silent --retry 10 --retry-connrefused --retry-delay 1 \
  "http://127.0.0.1:$port/healthz"
echo 'Image version, Lua, NDK rewrite, chroot, certgen and backend smoke checks passed.'
