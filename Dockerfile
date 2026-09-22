# syntax=docker/dockerfile:1
#
# iot-tig-lite – MQTT broker + Telegraf + InfluxDB 1.x + Grafana in one small container.
#
# Build (multi-arch):
#   docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -t lysek01/iot-tig-lite .

ARG ALPINE_VERSION=3.24
ARG GO_VERSION=1.27
ARG TELEGRAF_VERSION=1.40.1
ARG INFLUXDB_VERSION=1.8.10
ARG GRAFANA_VERSION=13.2.2

# ---------------------------------------------------------------------
# Telegraf – custom build with only the plugins this image needs.
# Cross-compiled on the build machine (no emulation needed).
# ---------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS telegraf
ARG TELEGRAF_VERSION
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
RUN apk add --no-cache git
RUN git clone --quiet --depth 1 --branch v${TELEGRAF_VERSION} https://github.com/influxdata/telegraf.git /src
WORKDIR /src
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    export CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} GOARM="${TARGETVARIANT#v}" && \
    go build -trimpath \
      -tags "custom,inputs.mqtt_consumer,inputs.cpu,inputs.mem,inputs.disk,inputs.system,inputs.temp,inputs.filecount,outputs.influxdb,parsers.value,parsers.influx,serializers.influx,processors.starlark" \
      -ldflags "-s -w -X github.com/influxdata/telegraf/internal.Version=${TELEGRAF_VERSION}" \
      -o /out/telegraf ./cmd/telegraf

# ---------------------------------------------------------------------
# Upstream images – used only as a source of binaries.
# ---------------------------------------------------------------------
FROM influxdb:${INFLUXDB_VERSION} AS influxdb-upstream
FROM grafana/grafana:${GRAFANA_VERSION} AS grafana-upstream

# ---------------------------------------------------------------------
# Slim down InfluxDB and Grafana (strip debug info, drop unused parts).
# Runs on the build machine; strip from binutils-multiarch handles all targets.
# ---------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends binutils-multiarch >/dev/null && rm -rf /var/lib/apt/lists/*
COPY --from=influxdb-upstream /usr/bin/influxd /out/usr/bin/influxd
COPY --from=grafana-upstream /usr/share/grafana /out/usr/share/grafana
RUN set -e; \
    strip /out/usr/bin/influxd /out/usr/share/grafana/bin/grafana; \
    cd /out/usr/share/grafana; \
    # source maps and the Swagger API browser are not needed at runtime
    find public -name '*.map' -delete; \
    rm -rf public/build-swagger public/api-merged.json public/openapi3.json; \
    # UI in English only
    find public/locales -mindepth 1 -maxdepth 1 ! -name en-US -exec rm -rf {} +; \
    # keep only the InfluxDB data source from the bundled (decoupled) plugins
    if [ -d data/plugins-bundled ]; then \
      find data/plugins-bundled -mindepth 1 -maxdepth 1 ! -name influxdb -exec rm -rf {} +; \
    fi; \
    # large cloud data sources we never use
    rm -rf public/app/plugins/datasource/azuremonitor public/app/plugins/datasource/cloudwatch

# ---------------------------------------------------------------------
# Final image
# ---------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION}
ARG TELEGRAF_VERSION
ARG INFLUXDB_VERSION
ARG GRAFANA_VERSION

RUN apk add --no-cache bash tini su-exec curl jq tzdata ca-certificates gcompat mosquitto mosquitto-clients \
 && addgroup -S -g 472 grafana && adduser -S -D -H -u 472 -G grafana grafana \
 && mkdir -p /var/lib/influxdb /var/lib/grafana /var/log/grafana /mosquitto/config /mosquitto/data /mosquitto/log \
             /etc/telegraf/telegraf.d \
 && rm -f /etc/mosquitto/mosquitto.conf

COPY --from=telegraf /out/telegraf /usr/bin/telegraf
COPY --from=slim /out/ /
RUN ln -s /usr/share/grafana/bin/grafana /usr/bin/grafana
COPY rootfs/ /
# tolerate Windows line endings when building from a Windows checkout
RUN find /usr/local/bin /etc/influxdb /etc/grafana /usr/share/iot-tig-lite -type f -exec sed -i 's/\r$//' {} + \
 && chmod +x /usr/local/bin/*

ENV IOT_TIG_LITE_VERSIONS="telegraf ${TELEGRAF_VERSION}, influxdb ${INFLUXDB_VERSION}, grafana ${GRAFANA_VERSION}" \
    # --- MQTT ---
    MQTT_BROKER=internal \
    MQTT_USERNAME= \
    MQTT_PASSWORD= \
    MQTT_TOPICS=# \
    MQTT_FORMAT=auto \
    # --- InfluxDB ---
    INFLUXDB_DB=iot \
    INFLUXDB_USER=iot \
    INFLUXDB_USER_PASSWORD=iot \
    INFLUXDB_ADMIN_USER=admin \
    INFLUXDB_ADMIN_PASSWORD=admin \
    INFLUXDB_RETENTION=30d \
    # --- Grafana ---
    GF_PATHS_HOME=/usr/share/grafana \
    GF_PATHS_CONFIG=/etc/grafana/grafana.ini \
    GF_PATHS_DATA=/var/lib/grafana \
    GF_PATHS_LOGS=/var/log/grafana \
    GF_PATHS_PLUGINS=/var/lib/grafana/plugins \
    GF_PATHS_PROVISIONING=/etc/grafana/provisioning \
    # --- Other ---
    SYSTEM_METRICS=true \
    TZ=Europe/Prague

# 3000 Grafana, 1883 MQTT, 9001 MQTT over WebSockets, 8086 InfluxDB HTTP API
EXPOSE 3000 1883 9001 8086

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 CMD ["/usr/local/bin/healthcheck"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/iot-tig-lite"]
