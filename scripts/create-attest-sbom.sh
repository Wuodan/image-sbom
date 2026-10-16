#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

missing_tools=""
for tool in jq crane syft cosign; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    missing_tools="${missing_tools} ${tool}"
  fi
done

if [ -n "${missing_tools}" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "[create-attest-sbom] missing required tools:${missing_tools}" >&2
    printf '%s\n' "[create-attest-sbom] install them or Docker to use ghcr.io/gh-workflow/image-sbom." >&2
    exit 1
  fi

  script_path="${SCRIPT_DIR}/$(basename -- "$0")"
  working_dir=$(pwd -P)
  tools_image="${IMAGE_SBOM_TOOLS_IMAGE:-ghcr.io/gh-workflow/image-sbom:v1}"
  env_file=$(mktemp)
  trap 'rm -f "${env_file}"' EXIT HUP INT TERM
  env | grep -E '^(COSIGN|SIGSTORE|REGISTRY)_[A-Za-z0-9_]*=' >"${env_file}" || true

  docker run --rm \
    --env-file "${env_file}" \
    -v "${script_path}:/image-sbom/create-attest-sbom.sh:ro" \
    -v "${working_dir}:${working_dir}" \
    -w "${working_dir}" \
    "${tools_image}" /image-sbom/create-attest-sbom.sh "$@"
  exit $?
fi

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

image_repo="${IMAGE}"
if [ "${image_repo}" != "${image_repo%@sha256:*}" ]; then
  image_repo="${image_repo%@sha256:*}"
else
  last_path="${image_repo##*/}"
  if [ "${last_path}" != "${last_path%:*}" ]; then
    image_repo="${image_repo%:*}"
  fi
fi

image_registry="${image_repo%%/*}"
local_registry="localhost" # DevSkim: ignore DS162092
if [ "${image_registry}" = "${image_registry#*.}" ] && [ "${image_registry}" = "${image_registry#:*}" ] && [ "${image_registry}" != "${local_registry}" ]; then
  image_registry="docker.io"
fi

if [ -n "${REGISTRY_USERNAME}" ]; then
  printf '%s\n' "${REGISTRY_PASSWORD}" |
    crane auth login "${image_registry}" \
      --username "${REGISTRY_USERNAME}" \
      --password-stdin
fi

attempt=1
while [ "${attempt}" -le 5 ]; do
  if manifest_json="$(crane manifest "${IMAGE}" 2>&1)"; then
    break
  fi
  if [ "${attempt}" -eq 5 ]; then
    die "${manifest_json}"
  fi
  attempt=$((attempt + 1))
  sleep 5
done

media_type="$(printf '%s\n' "${manifest_json}" | jq -r '.mediaType // ""')"

case "${media_type}" in
  application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json)
    resolved_images="$(
      printf '%s\n' "${manifest_json}" | jq -r --arg image_repo "${image_repo}" '
        .manifests[]
        | select(.platform.os != null and .platform.architecture != null)
        | select(.platform.os != "unknown" and .platform.architecture != "unknown")
        | select(.annotations["vnd.docker.reference.type"] != "attestation-manifest")
        | "\($image_repo)@\(.digest)"
      '
    )"
    ;;
  application/vnd.oci.image.manifest.v1+json | application/vnd.docker.distribution.manifest.v2+json)
    resolved_images="${image_repo}@$(crane digest "${IMAGE}")"
    ;;
  *)
    die "Unsupported image media type '${media_type}' for '${IMAGE}'"
    ;;
esac

[ -n "${resolved_images}" ] || die "No runnable image manifests found in '${IMAGE}'"
printf '%s\n' "${resolved_images}" >"${SBOM_DIR}/resolved-images.txt"

signing_config="${SBOM_DIR}/cosign-signing-config.json"
cosign signing-config create \
  --with-default-services \
  --no-default-rekor \
  --out "${signing_config}"

printf '%s\n' "${resolved_images}" | while IFS= read -r image; do
  [ -n "${image}" ] || continue
  image_digest="${image##*@}"
  sbom_file="${SBOM_DIR}/${image_digest#sha256:}.${SBOM_EXT}"

  if [ -n "${REGISTRY_USERNAME}" ]; then
    export SYFT_REGISTRY_AUTH_AUTHORITY="${image_registry}"
    export SYFT_REGISTRY_AUTH_USERNAME="${REGISTRY_USERNAME}"
    export SYFT_REGISTRY_AUTH_PASSWORD="${REGISTRY_PASSWORD}"
  fi

  "${SYFT_CMD:-syft}" scan "registry:${image}" -o "${FORMAT}" >"${sbom_file}"
  if [ -n "${REGISTRY_USERNAME}" ]; then
    cosign attest --yes --type "${PREDICATE_TYPE}" --signing-config "${signing_config}" \
      --registry-username "${REGISTRY_USERNAME}" --registry-password "${REGISTRY_PASSWORD}" \
      "$@" --predicate "${sbom_file}" "${image}"
  else
    cosign attest --yes --type "${PREDICATE_TYPE}" --signing-config "${signing_config}" \
      "$@" --predicate "${sbom_file}" "${image}"
  fi
done
