#!/usr/bin/env python3
"""Generate Helm overrides from the digests Docker returned after publication."""
import json
import os
import subprocess

registry = os.environ.get('REGISTRY', 'ghcr.io/jaredpricedev/ingress-nginx')
tag = os.environ['PATCHED_TAG']

def digest(name):
    image = f'{registry}/{name}:{tag}'
    values = json.loads(subprocess.check_output(
        ['docker', 'image', 'inspect', '--format', '{{json .RepoDigests}}', image], text=True))
    prefix = f'{registry}/{name}@'
    matches = [value[len(prefix):] for value in values or [] if value.startswith(prefix)]
    if len(matches) != 1:
        raise SystemExit(f'Expected one published digest for {image}, found {matches}')
    return matches[0]

controller = digest('controller')
chroot = digest('controller-chroot')
certgen = digest('kube-webhook-certgen')
backend = digest('custom-error-pages')
host, path = registry.split('/', 1)
print(f'''# Generated from published images; linux/amd64 only.
controller:
  image:
    registry: {host}
    image: {path}/controller
    tag: "{tag}"
    digest: {controller}
    digestChroot: {chroot}
  admissionWebhooks:
    patch:
      image:
        registry: {host}
        image: {path}/kube-webhook-certgen
        tag: "{tag}"
        digest: {certgen}
defaultBackend:
  image:
    registry: {host}
    image: {path}/custom-error-pages
    tag: "{tag}"
    digest: {backend}
''')
