#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/lib.sh"
image_sbom_require_tools "$0" "jq crane syft cosign" "$@"

usage() {
  cat <<'USAGE'
Usage: create-attest-sbom.sh [options] <image> [-- <cosign attest options>]

Generate and attach an SBOM for every runnable platform in an image.

Options:
  --format <value>             spdx-json (default) or cyclonedx-json
  --output-dir <directory>     Directory for generated SBOM files (default: ./sbom)
  --registry-username <value>  Registry username
  --registry-password <value>  Registry password or token
  -h, --help                   Show this help and exit
USAGE
  exit 1
}

die() {
  echo "[create-attest-sbom] $*" >&2
  exit 1
}

FORMAT=spdx-json
SBOM_DIR=./sbom
REGISTRY_USERNAME=
REGISTRY_PASSWORD=
IMAGE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --format | --output-dir | --registry-username | --registry-password)
      [ "$#" -ge 2 ] || die "$1 requires a value"
      case "$1" in
        --format) FORMAT="$2" ;;
        --output-dir) SBOM_DIR="$2" ;;
        --registry-username) REGISTRY_USERNAME="$2" ;;
        --registry-password) REGISTRY_PASSWORD="$2" ;;
      esac
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
      [ -z "${IMAGE}" ] || die "Unexpected extra argument '$1'"
      IMAGE="$1"
      shift
      ;;
  esac
done

[ -n "${IMAGE}" ] || usage
if [ -n "${REGISTRY_USERNAME}" ] || [ -n "${REGISTRY_PASSWORD}" ]; then
  [ -n "${REGISTRY_USERNAME}" ] && [ -n "${REGISTRY_PASSWORD}" ] ||
    die "--registry-username and --registry-password must be provided together"
fi

case "${FORMAT}" in
  spdx-json)
    PREDICATE_TYPE=spdxjson
    SBOM_EXT=spdx.json
    ;;
  cyclonedx-json)
    PREDICATE_TYPE=cyclonedx
    SBOM_EXT=cyclonedx.json
    ;;
  *)
    die "Unsupported format '${FORMAT}'. Supported values are: spdx-json, cyclonedx-json."
    ;;
esac

mkdir -p "${SBOM_DIR}"
export FORMAT SBOM_DIR REGISTRY_USERNAME REGISTRY_PASSWORD PREDICATE_TYPE SBOM_EXT
export SYFT_CMD="${SYFT_CMD:-syft}"

"${SCRIPT_DIR}/resolve-image-manifests.sh"
RESOLVED_IMAGES_FILE="${SBOM_DIR}/resolved-images.txt"
export RESOLVED_IMAGES_FILE
"${SCRIPT_DIR}/generate-attest-sbom.sh" "$@"
