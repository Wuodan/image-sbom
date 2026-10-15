#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/lib.sh"
image_sbom_require_tools "$0" "crane jq cosign" "$@"

usage() {
  cat <<'USAGE'
Usage: show-sbom.sh [--packages] [--platform <platform>] <image>

Print the SPDX SBOM attested to a published image.

Options:
  --packages          Print package name, version, and supplier as tab-separated values
  --platform <value>  Platform to print (default: linux/amd64)
  -h, --help          Show this help and exit
USAGE
  exit 1
}

die() {
  echo "[show-sbom] $*" >&2
  exit 1
}

IMAGE_REF=""
PLATFORM="linux/amd64"
PACKAGES_ONLY=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --packages)
      PACKAGES_ONLY=true
      shift
      ;;
    --platform)
      [ "$#" -ge 2 ] || die "--platform requires a value"
      PLATFORM="$2"
      shift 2
      ;;
    -h | --help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option '$1'"
      ;;
    *)
      if [ -n "${IMAGE_REF}" ]; then
        die "Unexpected extra argument '$1'"
      fi
      IMAGE_REF="$1"
      shift
      ;;
  esac
done

[ -n "${IMAGE_REF}" ] || usage

image_repo="${IMAGE_REF}"
if [ "${image_repo}" != "${image_repo%@sha256:*}" ]; then
  image_repo="${image_repo%@sha256:*}"
else
  last_path="${image_repo##*/}"
  if [ "${last_path}" != "${last_path%:*}" ]; then
    image_repo="${image_repo%:*}"
  fi
fi

platform_os="${PLATFORM%%/*}"
platform_rest="${PLATFORM#*/}"
[ "${platform_rest}" != "${PLATFORM}" ] || die "Invalid platform '${PLATFORM}'"
platform_architecture="${platform_rest%%/*}"
platform_variant=""
if [ "${platform_rest}" != "${platform_architecture}" ]; then
  platform_variant="${platform_rest#*/}"
fi

manifest_json="$(crane manifest "${IMAGE_REF}")" || die "Could not inspect '${IMAGE_REF}'"
media_type="$(printf '%s\n' "${manifest_json}" | jq -r '.mediaType // ""')"

case "${media_type}" in
  application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json)
    resolved_digest="$(
      printf '%s\n' "${manifest_json}" |
        jq -r \
          --arg os "${platform_os}" \
          --arg architecture "${platform_architecture}" \
          --arg variant "${platform_variant}" '
            .manifests[]
            | select(.platform.os == $os and .platform.architecture == $architecture)
            | select($variant == "" or .platform.variant == $variant)
            | select(.annotations["vnd.docker.reference.type"] != "attestation-manifest")
            | .digest
          ' |
        head -n 1
    )"
    [ -n "${resolved_digest}" ] || die "Could not find platform '${PLATFORM}' in '${IMAGE_REF}'"
    resolved_image="${image_repo}@${resolved_digest}"
    ;;
  application/vnd.oci.image.manifest.v1+json | application/vnd.docker.distribution.manifest.v2+json)
    resolved_image="${image_repo}@$(crane digest "${IMAGE_REF}")"
    ;;
  *)
    die "Unsupported image media type '${media_type}' for '${IMAGE_REF}'"
    ;;
esac

SPDX_SBOM="$(
  cosign download attestation \
    --predicate-type https://spdx.dev/Document \
    "${resolved_image}" |
    jq -se '
      [
        .[]
        | (.payload // .dsseEnvelope.payload)
        | @base64d
        | fromjson
        | .predicate
      ]
      | if length == 0 then error("No SPDX SBOM attestation found") else .[0] end
    '
)" || die "No SPDX SBOM attestation found for '${resolved_image}'"

if [ "${PACKAGES_ONLY}" = true ]; then
  printf 'NAME\tVERSION\tSUPPLIER\n'
  printf '%s\n' "${SPDX_SBOM}" |
    jq -r '.packages[] | [.name, .versionInfo, (.supplier // "")] | @tsv' |
    sort -u
else
  printf '%s\n' "${SPDX_SBOM}"
fi
