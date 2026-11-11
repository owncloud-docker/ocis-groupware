# syntax=docker/dockerfile:1

FROM --platform=$BUILDPLATFORM node:26.12.1-bookworm-slim@sha256:88e480776c6149ff1d098cd304f44bf18057fb5d284a3329b78162d29821e28c AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web ./
RUN npm run build

FROM --platform=$BUILDPLATFORM golang:1.27.4-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea AS build
WORKDIR /src
ENV CGO_ENABLED=0
# Set by buildx. The Go toolchain cross-compiles, so no emulation is needed.
ARG TARGETOS
ARG TARGETARCH
ENV GOOS=$TARGETOS GOARCH=$TARGETARCH

COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal
COPY web/*.go ./web/
COPY --from=web /src/web/dist ./web/dist
RUN go build -trimpath -ldflags="-s -w" -o /out/ocis-groupware ./cmd/ocis-groupware
# Distroless has no shell, so the data directory is created here and copied over with its owner.
RUN mkdir /out/data

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/ocis-groupware /ocis-groupware
COPY --from=build --chown=65532:65532 /out/data /data
ENV GROUPWARE_DATA_DIR=/data
VOLUME /data
# The debug listener (/metrics, /healthz) binds to the loopback interface by
# default, which cannot be reached from outside a container. Listen on all
# interfaces here and do not publish this port beyond the monitoring network.
ENV GROUPWARE_DEBUG_ADDR=:9180
EXPOSE 8080 9180
ENTRYPOINT ["/ocis-groupware"]
