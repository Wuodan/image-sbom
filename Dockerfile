# syntax=docker/dockerfile:1

FROM ghcr.io/sigstore/cosign/cosign:v3.0.2@sha256:b29487e48205d875c324c79583e2806d9d269c0fa299e0861bbec023d8430c8b AS cosign
FROM anchore/syft:v1.20.0@sha256:b46e597614ddc78621e560af3fabf9346e35462ea1c886a38b30bcc7ca601a73 AS syft
FROM gcr.io/go-containerregistry/crane:debug@sha256:e78770b31258a3846f878036d9c1f63fbe4c871f9f56990bf77fd95c013e3c1b AS crane

FROM alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507

RUN apk add --no-cache ca-certificates jq

COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign
COPY --from=syft /syft /usr/local/bin/syft
COPY --from=crane /ko-app/crane /usr/local/bin/crane

ENTRYPOINT ["/bin/sh"]
