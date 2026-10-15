# Image SBOM

[![GitHub Marketplace](https://img.shields.io/badge/marketplace-image--sbom-blue?logo=github&labelColor=333&style=flat-square)](https://github.com/marketplace/actions/image-sbom)
[![Release](https://img.shields.io/github/v/release/gh-workflow/image-sbom?style=flat-square)](https://github.com/gh-workflow/image-sbom/releases)
[![Immutable Releases](https://img.shields.io/badge/releases-immutable-blue?labelColor=333)](https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/immutable-releases)
[![Tests](https://img.shields.io/github/actions/workflow/status/gh-workflow/image-sbom/.github/workflows/ci_live-test.yml?branch=main&label=test&style=flat-square)](https://github.com/gh-workflow/image-sbom/actions/workflows/ci_live-test.yml)

Generate an SBOM for each resolved container image and attach it as a Cosign attestation.

This action is useful when `docker/build-push-action` BuildKit SBOM generation hits the attestation size limit, for
example:

```text
sbom.spdx.json exceeds 41943040 bytes
```

Instead of using `sbom: true` on the Docker build step, push the image first and run this action against the immutable
digest reference.

## Usage

Set these permissions on the job or workflow:

```yaml
permissions:
  id-token: write
  packages: write
```

Run this action after the image has been pushed:

```yaml
- name: Build and push
  id: build
  uses: docker/build-push-action@v7
  with:
    context: .
    push: true
    sbom: false
    tags: ghcr.io/${{ github.repository }}:latest

- name: Generate and attest SBOM
  uses: gh-workflow/image-sbom@v1
  with:
    image: ghcr.io/${{ github.repository }}@${{ steps.build.outputs.digest }}
    registry-username: ${{ github.actor }}
    registry-password: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

<!-- markdownlint-disable MD013 -->
| Name                | Required | Default     | Description                                                                     |
|---------------------|----------|-------------|---------------------------------------------------------------------------------|
| `image`             | Yes      |             | Image reference to scan and attest. Prefer an immutable digest reference.       |
| `registry-username` | No       |             | Registry username used by Syft and Cosign for image registry access.            |
| `registry-password` | No       |             | Registry password or token used by Syft and Cosign for image registry access.   |
| `format`            | No       | `spdx-json` | SBOM format to generate. Supported values are `spdx-json` and `cyclonedx-json`. |
<!-- markdownlint-enable MD013 -->

If either `registry-username` or `registry-password` is provided, both must be
provided. For GHCR images, use `${{ github.actor }}` and
`${{ secrets.GITHUB_TOKEN }}`. Do not embed credentials in the `image` reference.

The selected `format` controls the Cosign predicate type automatically:

| Format           | Cosign predicate type |
|------------------|-----------------------|
| `spdx-json`      | `spdxjson`            |
| `cyclonedx-json` | `cyclonedx`           |

## Permissions

The calling workflow needs `id-token: write` for Cosign keyless signing. For
GHCR images, it also needs `packages: write` so Cosign can push the attestation.

## Outputs

| Name       | Description                                    |
|------------|------------------------------------------------|
| `sbom-dir` | Directory containing the generated SBOM files. |

## Image references

The image must already be available to Syft and Cosign. Syft can scan images
from local container runtimes or registries, but Cosign needs a registry image
reference when uploading the attestation. A digest reference is recommended so
the SBOM is attached to the exact image that was built.

## Development

See the [development documentation](docs/development.md) for developer
information.

## Inspect published SBOMs

This repository includes an optional helper to read an SPDX SBOM attested by this action. With [`jq`](https://jqlang.org/)
and [Cosign](https://docs.sigstore.dev/cosign/system_config/installation/) installed, it runs directly. Otherwise, it
uses Docker and the published tools image automatically:

```bash
curl -fsSLO https://raw.githubusercontent.com/gh-workflow/image-sbom/v1/scripts/{lib,show-sbom}.sh
chmod +x show-sbom.sh
./show-sbom.sh --packages <image-reference>
```

Replace `<image-reference>` with the image tag or digest to inspect. Omit `--packages` to print the complete SPDX
document. For a multi-platform image, use `--platform linux/arm64` to select a platform other than the default
`linux/amd64`.

## Generate and attest SBOMs locally

Use the standalone creator outside GitHub Actions. It generates one SBOM per runnable image platform, writes the
documents to `./sbom`, and attaches each as a Cosign attestation. The scripts run with local `jq`, Crane, Syft, and
Cosign installations, or automatically use Docker and the published tools image when those tools are absent:

```bash
curl -fsSLO https://raw.githubusercontent.com/gh-workflow/image-sbom/v1/scripts/{lib,resolve-image-manifests,generate-attest-sbom,create-attest-sbom}.sh
chmod +x create-attest-sbom.sh resolve-image-manifests.sh generate-attest-sbom.sh
./create-attest-sbom.sh <image-reference>
```

Pass any Cosign attestation options after `--`:

```bash
./create-attest-sbom.sh <image-reference> -- --key ./cosign.key
```

## License

MIT
