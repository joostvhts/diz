# syntax=docker/dockerfile:1
#
# Diz bridge: a small, non-root, multi-arch image (linux/arm64, linux/amd64).
#
#   docker build -t diz-bridge:0.2.0 .
#   docker buildx build --platform linux/arm64 -t diz-bridge:0.2.0 .
#
# The binary is cross-compiled on the build machine's own architecture
# (dart compile exe --target-arch), so building the arm64 image on an x64
# machine needs no emulation. The final image is `scratch` plus the few shared
# libraries a Dart AOT binary needs; it has no shell.

# Pinned by tag and digest. Bump both together.
ARG DART_IMAGE=dart:3.11.6@sha256:2ed474dc085f267ca692261ce35b23a0ae039e317beebef854be886c8b57832d

FROM --platform=$BUILDPLATFORM ${DART_IMAGE} AS build
ARG TARGETARCH
WORKDIR /src

# Resolve dependencies first, so this layer is cached until a pubspec changes.
# The workspace also lists the Flutter app, which isn't needed (or buildable) here.
COPY pubspec.yaml pubspec.lock ./
COPY packages/diz_core/pubspec.yaml packages/diz_core/
COPY bridge/pubspec.yaml bridge/
RUN sed -i '/^  - app$/d' pubspec.yaml && dart pub get

COPY packages/diz_core/ packages/diz_core/
COPY bridge/ bridge/
RUN case "$TARGETARCH" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH (use linux/arm64 or linux/amd64)" >&2; exit 1 ;; \
    esac \
 && version="$(sed -n 's/^version: *//p' bridge/pubspec.yaml)" \
 && mkdir -p /out/data \
 && dart compile exe bridge/bin/diz_bridge.dart \
      --target-os=linux --target-arch="$arch" -DDIZ_VERSION="$version" \
      -o /out/diz-bridge

# Shared libraries (glibc etc.) for the *target* architecture. Nothing runs in
# this stage, so cross-building needs no emulation here either.
FROM ${DART_IMAGE} AS runtime

FROM scratch
LABEL org.opencontainers.image.title="diz-bridge" \
      org.opencontainers.image.description="Local control for WiZ lights: HTTP API + WiZ UDP bridge"
COPY --from=runtime /runtime/ /
COPY --from=build /out/diz-bridge /usr/local/bin/diz-bridge
# /data holds lights.json (names and known lamps); mount a volume here.
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532

ENV DIZ_HOST=0.0.0.0 \
    DIZ_PORT=8787 \
    DIZ_STATE_DIR=/data \
    DIZ_BROADCAST=off

# 8787/tcp: HTTP API (put a TLS reverse proxy in front). 38900/udp: lamp status pushes.
EXPOSE 8787/tcp 38900/udp
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/usr/local/bin/diz-bridge", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/diz-bridge"]
