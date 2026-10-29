# Patched image builds

This is Jared Price's experimental maintenance fork of the retired
`kubernetes/ingress-nginx` project. Upstream controller v1.15.1 is the source
baseline. These changes do not restore Kubernetes project support or establish
FIPS/STIG compliance.

## Patch baseline (2026-10-29)

| Component | Upstream build | Fork build |
| --- | --- | --- |
| Alpine | 3.23.3 | 3.23.7, with current packages from the 3.23 branch |
| Go toolchain | 1.26.1 | 1.26.10 (patched supported minor line) |
| NGINX | 1.27.1 plus upstream backports | 1.30.6 (current stable line) |
| njs | 0.9.0 | 1.0.2 |
| Distroless helpers | implicit Debian version / Debian 11 example | explicit Debian 13 |

NGINX is compiled from source; changing Alpine alone would not patch it. Its
tarball SHA256 is checked before extraction. All 34 retained ingress/OpenResty
patches are rebased for `patch --fuzz=0`. The old CVE-2025-23419 backport is
removed because NGINX 1.30.6 includes that fix. NDK and set-misc patches preserve
variable-based URI escaping after NGINX's rewrite-engine security fixes.

The image set is `nginx`, `controller`, `controller-chroot`,
`kube-webhook-certgen`, and `custom-error-pages`. The last image can replace the
old optional `defaultbackend-amd64:1.5`; the generated overrides preserve whether
the backend is enabled. Builds currently target native **linux/amd64** only.

## Build and validation

The **Patched Images** workflow runs on relevant pull requests. It runs Go unit
tests, builds fresh images, and exercises version reporting, Lua, variable-based
`set_escape_uri`, the chroot wrapper, certgen help, and the backend health endpoint.
It records full vulnerability reports and CycloneDX SBOMs for every image.
Fixable HIGH/CRITICAL findings fail the workflow and prevent publication.
Unfixed findings remain visible in the full reports. Source-built NGINX and
third-party modules also require advisory review; a clean Trivy report alone is
not proof they are unaffected.

For a local build with Docker, Bash, and Go from `GOLANG_VERSION` installed:

```sh
bash hack/build-patched-images.sh
```

The legacy upstream `make release` and `NGINX_BASE` still refer to upstream's
release process. Use this fork's workflow or build script for patched images;
they always compile the patched NGINX base first.

## Publish and consume

After reviewing and merging the changes, run **Patched Images** from `main` in
GitHub Actions and select `publish: true`. Publication happens only after build,
smoke checks and scans pass. The workflow uses the repository's `GITHUB_TOKEN`
for GHCR, with no Docker Hub or Kubernetes staging credentials. Every run uses a
unique tag including its commit SHA, run ID and attempt.

Download the run's `patched-images-*` artifact. Its `values.yaml` is generated
only after successful pushes and contains actual registry digests for the
controller, chroot variant, admission helper and optional default backend.

```sh
helm upgrade --install ingress-nginx ./charts/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f your-existing-values.yaml -f values.yaml
```

The chart and provider manifests retain the last published upstream image
references until this artifact is supplied. No fabricated digest or unpublished
fork image is set as a deployment default. Verify GHCR package pull access before
importing the images into an internal registry. The workflow does not deploy to
any cluster. Integration testing on a disposable Kubernetes cluster is still
required before production use, especially TLS/client certificates, auth,
rewrites, WebSockets, TCP/UDP, reloads, ModSecurity and OpenTelemetry.

## Sources and patch provenance

- [Upstream retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [NGINX releases](https://nginx.org/en/download.html) and
  [security advisories](https://nginx.org/en/security_advisories.html)
- [Go release history](https://go.dev/doc/devel/release)
- [Alpine security release](https://www.alpinelinux.org/posts/Alpine-3.21.9-3.22.7-3.23.7-3.24.3-released.html)
- The NGINX patch rebase starts from
  [baranchen/ingress-nginx at 7ed2b926](https://github.com/baranchen/ingress-nginx/tree/7ed2b9269945e1de1bc4d843f3d3aee8d7698de4/images/nginx/rootfs/patches),
  then regenerates context against the official 1.30.6 tarball. Existing upstream
  behavior is retained, including removal of the `root` and `alias` directives.
- NDK and set-misc compatibility fixes come from
  [forkline/ingress-nginx at a6522126](https://github.com/forkline/ingress-nginx/tree/a652212694663c1095cd38c201ce8674d277d157/images/nginx/rootfs/patches).
  The NDK patch identifies its originating upstream PR in its source comments.

Other vendored modules and Go dependencies are retained at their existing pins.
Dependabot continues to propose Docker, Go and Actions updates. Security review
and integration testing are needed for future controller and module findings;
this fork is a bridge for existing deployments while planning migration.
