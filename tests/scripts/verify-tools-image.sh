#!/bin/sh
set -eu

: "${IMAGE:?}"

docker run --rm "${IMAGE}" -c '
  set -eu
  cosign version >/dev/null
  cosign signing-config create --with-default-services --no-default-rekor >/dev/null
  syft version >/dev/null
  crane version >/dev/null
  jq --version >/dev/null
'
