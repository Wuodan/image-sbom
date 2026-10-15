#!/bin/sh

image_sbom_require_tools() {
  script_path="$1"
  required_tools="$2"
  shift 2

  if [ "${IMAGE_SBOM_IN_TOOLS_IMAGE:-}" = "1" ]; then
    return
  fi

  missing_tools=""
  for tool in ${required_tools}; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      missing_tools="${missing_tools} ${tool}"
    fi
  done

  [ -z "${missing_tools}" ] && return

  if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "[image-sbom] missing required tools:${missing_tools}" >&2
    printf '%s\n' "[image-sbom] install them or install Docker to run this script in ghcr.io/gh-workflow/image-sbom." >&2
    exit 1
  fi

  script_dir=$(CDPATH= cd -- "$(dirname -- "${script_path}")" && pwd)
  script_name=$(basename -- "${script_path}")
  working_dir=$(pwd -P)
  tools_image="${IMAGE_SBOM_TOOLS_IMAGE:-ghcr.io/gh-workflow/image-sbom:v1}"

  env_file=$(mktemp)
  trap 'rm -f "${env_file}"' EXIT HUP INT TERM
  env | grep -E '^(COSIGN|SIGSTORE|REGISTRY)_[A-Za-z0-9_]*=|^(IMAGE|PLATFORM|PACKAGES_ONLY|FORMAT|PREDICATE_TYPE|SBOM_DIR|SBOM_EXT|SYFT_CMD|RUNNER_TEMP)=' >"${env_file}" || true

  docker run --rm --entrypoint /bin/sh \
    --env-file "${env_file}" \
    -e IMAGE_SBOM_IN_TOOLS_IMAGE=1 \
    -v "${script_dir}:/image-sbom/scripts:ro" \
    -v "${working_dir}:${working_dir}" \
    -w "${working_dir}" \
    "${tools_image}" "/image-sbom/scripts/${script_name}" "$@"
  exit $?
}
