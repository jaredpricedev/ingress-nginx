# Patched images for chart 4.12.3 / controller 1.12.3

This fork targets an existing installation of **Helm chart 4.12.3 and controller
v1.12.3**. The source baseline is upstream commit
`af6352cbe46e3c384c69c28257efa99535b97c80`. The entire `charts/ingress-nginx`
directory stays unchanged, including its version, appVersion, resources and
defaults. Fork images use distinct `v1.12.3-patch.*` tags; they are not official
upstream v1.12.3 images. Upstream retirement still applies.

## Compatibility boundaries

The Kubernetes clients, controller features, command flags, chart schema and
default configuration come from v1.12.3. In particular, the NGINX substitutions
filter is retained; replacing this build with a newer controller's NGINX module
set would remove it. We do not update this installation to controller v1.15.

Security fixes intentionally change unsafe configuration handling. Auth methods
must be complete allowed HTTP method names; proxy cookie domain values must be
`off` or two supported domain tokens; annotation aliases obey their original risk
level; Ingress UIDs must be normalized UUIDs; admission requests of 9 MiB or more
are rejected. Locations, server names and auth proxy headers are escaped, and
auth subrequests bypass custom error interception. Configurations that relied on
previously accepted injection characters can behave differently or be rejected.

The NGINX engine, Lua modules, Alpine packages and ModSecurity CRS change too.
These need runtime testing, especially regex paths and rewrites, external auth,
TLS/client certificates, WebSockets, TCP/UDP, ModSecurity, OpenTelemetry and custom
snippets/templates. Identical chart resources do not guarantee identical request
handling. Kubernetes 1.28 and 1.32 are the endpoints of the original support
matrix; the workflow tests a chart upgrade on both, with the routing checks below.
Your actual Kubernetes version and custom Helm values remain unverified.

## Security backports

Only image rebuilds would leave controller vulnerabilities unresolved. The
following upstream fixes are backported to the v1.12.3 source, with their tests.
No later controller feature release is merged wholesale.

| Advisory / hardening | Upstream commit | Change |
| --- | --- | --- |
| CVE-2025-15566 | `279cd7cad70980e4bf5a70a29c21d3302db5d1b1` | Quote auth proxy headers |
| CVE-2026-24514 | `8e910beffe7621a5c7edd31cdf319f66041df749` | Bound admission request reads |
| CVE-2026-24513 | `9685608059fff03918e05356f02ebc4e20c50917` | Disable custom error interception for auth |
| UID validation | `7cab49d97ed3c8dcc9f65dbb6a96dd70859f311c` | Reject non-normalized UUIDs |
| CVE-2026-24512 | `c423b85bee1ed47af95d27a7ddb7cfe3c73c1070` | Quote locations and server names |
| CVE-2026-1580 | `a91d165fcc9309f5739c5dc42c8a7497381ce111` | Anchor auth method validation |
| Cookie domain validation | `4d77e1ebb87b47f2bf82a8f2c01ce2177d31621e` | Validate both domain arguments |
| Annotation alias risk | `ab200035b822ee9be765bb65f42e362e648cdfa1` | Include aliases in risk checks |
| CVE-2026-3288 | `102217b69112b0d7d431afaf62ce8d9c12280f69` | Escape the rewrite path |
| CVE-2026-4342 | `0a2bf0c6266161e1acbf48c3d7ef79d54bc8c814` | Remove user paths from comments |

UID validation uses an equivalent local regular expression because the upstream
fix's `validate.UUID` API is absent from v1.12.3's Kubernetes library version.
It retains the same 36-character, lowercase hexadecimal, hyphenated format.
Tests introduced after v1.12.3 for unrelated features are not imported; existing
e2e assertions are updated for quoted directives.

## Image inputs (2026-10-29)

| Component | Original 1.12.3 build | Fork build |
| --- | --- | --- |
| Go compiler | 1.24.3 | 1.26.10 |
| Alpine | 3.21 | 3.23.7 plus current 3.23 packages |
| NGINX | 1.25.5 with backports | 1.30.6 with rebased ingress/OpenResty patches |
| Lua NGINX / stream | 0.10.26 / pinned snapshot | 0.10.28 / 0.0.16 |
| Lua resty core | 0.1.28 | 0.1.31 |
| ModSecurity connector / CRS | 1.0.3 / 4.10.0 | 1.0.4 / 4.22.0 |
| Helper runtime | implicit Distroless Debian version | explicit Debian 13 |

The NGINX tarball SHA256 is verified. Its 34 ingress/OpenResty patches apply
with `--fuzz=0`; the obsolete CVE-2025-23419 patch is already integrated in
NGINX 1.30.6. Additional NDK/set-misc patches retain variable-based URI escaping
after NGINX's rewrite-engine fixes. Module versions are pinned in `build.sh`;
remaining third-party archive checksums still need enforcement. Go module pins
start from v1.12.3 and are subject to the vulnerability scan gate; changing the
compiler alone does not patch those dependencies.

## Build and review

The **Patched Images** workflow builds `nginx`, `controller`, `controller-chroot`,
`kube-webhook-certgen` and `custom-error-pages`, for native **linux/amd64**.
It checks that chart files match the exact baseline, runs Go tests, and exercises
Lua, substitutions, URI escaping, chroot, certgen and backend health. On disposable
Kubernetes 1.28/1.32 clusters it installs the original chart, then upgrades only
the images with `--reuse-values`, checking HTTP, TLS, regex rewrite routing and
an admission update before/after the upgrade.

Full Trivy JSON reports and CycloneDX SBOMs are retained for all images. Fixable
HIGH/CRITICAL findings fail the workflow. Source-built modules need separate
advisory review; a clean scan alone cannot certify them. A failed build or scan
means the candidate is not ready. These tests cover fixtures, not your cluster's
custom values or every ingress-nginx feature.

For a local build with Docker, Bash and the Go compiler in `GOLANG_VERSION`:

```sh
bash hack/build-patched-images.sh
bash hack/test-patched-chart.sh # also requires kind, kubectl, Helm and PATCHED_TAG
```

## Publish and use with the existing chart

After validation and merge into `release-1.12.3`, run **Patched Images** with
`publish: true` on that branch. GitHub requires the dispatch workflow to also be
present on the repository default branch; set `release-1.12.3` as default after
merge if it remains absent from `main`. The workflow uses this fork's GHCR
namespace and `GITHUB_TOKEN`, with unique tags containing commit/run/attempt IDs.
Publication requires successful tests and scans. It never deploys to your cluster.

After successful publication, download the run's `patched-images-*` artifact.
Its `values.yaml` uses actual pushed image digests and the chart 4.12.3 keys:

```sh
helm upgrade ingress-nginx ingress-nginx/ingress-nginx --version 4.12.3 \
  --namespace ingress-nginx --reuse-values -f values.yaml --wait
```

Adapt the release name/namespace to your existing installation. Review
`helm get values` and `helm template` first, and test your real ingress routes
before production. Registry access must work from cluster nodes. The optional
default backend stays enabled or disabled according to your existing values.
Until published digests exist, the chart's original image references remain
unchanged; no candidate image is a deployment default.

## References

- [Upstream retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [Kubernetes security announcements](https://github.com/kubernetes/kubernetes/labels/official-cve-feed)
- [NGINX releases](https://nginx.org/en/download.html) and [security advisories](https://nginx.org/en/security_advisories.html)
- [Go release history](https://go.dev/doc/devel/release)
- NGINX patch rebase from [baranchen at 7ed2b926](https://github.com/baranchen/ingress-nginx/tree/7ed2b9269945e1de1bc4d843f3d3aee8d7698de4/images/nginx/rootfs/patches), regenerated against official 1.30.6.
- NDK/set-misc compatibility patches from [forkline at a6522126](https://github.com/forkline/ingress-nginx/tree/a652212694663c1095cd38c201ce8674d277d157/images/nginx/rootfs/patches).

This is an experimental maintenance fork, not restored Kubernetes project
support or a guarantee that all vulnerabilities have been removed.
