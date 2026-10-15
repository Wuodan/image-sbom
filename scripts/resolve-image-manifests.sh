#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/lib.sh"

image_sbom_require_tools "$0" "crane jq" "$@"

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
if [ "${image_registry}" != "${image_registry#*.}" ] || [ "${image_registry}" != "${image_registry#:*}" ] || [ "${image_registry}" = "${local_registry}" ]; then
  :
else
  image_registry="docker.io"
fi

if [ -n "${REGISTRY_USERNAME}" ] || [ -n "${REGISTRY_PASSWORD}" ]; then
  if [ -z "${REGISTRY_USERNAME}" ] || [ -z "${REGISTRY_PASSWORD}" ]; then
    echo "::error::registry-username and registry-password must be provided together."
    exit 1
  fi

  printf '%s\n' "${REGISTRY_PASSWORD}" |
    crane auth login "${image_registry}" \
      --username "${REGISTRY_USERNAME}" \
      --password-stdin
fi

# A registry may acknowledge a push before its manifest is readable; retry the
# inspection briefly so a just-pushed image can become available.
attempt=1
while [ "${attempt}" -le 5 ]; do
  if inspect_json="$(crane manifest "${IMAGE}" 2>&1)"; then
    break
  fi
  if [ "${attempt}" -eq 5 ]; then
    printf '%s\n' "${inspect_json}" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 5
done

media_type="$(printf '%s\n' "${inspect_json}" | jq -r '.mediaType // ""')"

case "${media_type}" in
  application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json)
    resolved_images="$(
      printf '%s\n' "${inspect_json}" | jq -r --arg image_repo "${image_repo}" '
        .manifests[]
        | select(.platform.os != null and .platform.architecture != null)
        | select(.platform.os != "unknown" and .platform.architecture != "unknown")
        | select(.annotations["vnd.docker.reference.type"] != "attestation-manifest")
        | "\($image_repo)@\(.digest)"
      '
    )"
    ;;
  application/vnd.oci.image.manifest.v1+json | application/vnd.docker.distribution.manifest.v2+json)
    digest="$(
      crane digest "${IMAGE}"
    )"
    if [ -z "${digest}" ]; then
      echo "::error::Could not resolve digest for ${IMAGE}."
      exit 1
    fi
    resolved_images="${image_repo}@${digest}"
    ;;
  *)
    echo "::error::Unsupported image media type '${media_type}' for ${IMAGE}."
    exit 1
    ;;
esac

if [ -z "${resolved_images}" ]; then
  echo "::error::No runnable image manifests found in ${IMAGE}."
  exit 1
fi

resolved_images_file="${SBOM_DIR}/resolved-images.txt"
printf '%s\n' "${resolved_images}" >"${resolved_images_file}"
