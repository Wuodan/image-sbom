#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/lib.sh"
image_sbom_require_tools "$0" "jq cosign" "$@"

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

SPDX_SBOM="$(
  cosign download attestation \
    --platform "${PLATFORM}" \
    --predicate-type https://spdx.dev/Document \
    "${IMAGE_REF}" |
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
)" || die "No SPDX SBOM attestation found for '${IMAGE_REF}' on platform '${PLATFORM}'"

if [ "${PACKAGES_ONLY}" = true ]; then
  printf 'NAME\tVERSION\tSUPPLIER\n'
  printf '%s\n' "${SPDX_SBOM}" |
    jq -r '.packages[] | [.name, .versionInfo, (.supplier // "")] | @tsv' |
    sort -u
else
  printf '%s\n' "${SPDX_SBOM}"
fi
