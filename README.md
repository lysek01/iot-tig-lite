# iot-tig-lite

**MQTT broker + Telegraf + InfluxDB 1.8 + Grafana in one small container.**
Send MQTT messages from your devices, see them in Grafana a few seconds later.
Configured with a single `.env` file, runs on a Raspberry Pi 3 / 4 / 5 and on any PC.

```
ESP32, sensors ──MQTT──▶ Mosquitto ──▶ Telegraf ──▶ InfluxDB 1.8 ──▶ Grafana
                         (built-in or your own broker)                :3000
```

| Platform | Image variant |
|---|---|
| Raspberry Pi 3 / 4 / 5 with 32-bit OS | `linux/arm/v7` |
| Raspberry Pi 3 / 4 / 5 with 64-bit OS | `linux/arm64` |
| PC / notebook / server | `linux/amd64` |

Docker picks the right variant automatically.

## Quick start

1. Install Docker (once):
   ```bash
   curl -fsSL https://get.docker.com | sudo sh
   sudo usermod -aG docker $USER && newgrp docker
   ```
2. Get the two files:
   ```bash
   mkdir iot-tig-lite && cd iot-tig-lite
   curl -fsSLO https://raw.githubusercontent.com/lysek01/iot-tig-lite/main/examples/compose.yaml
   curl -fsSL -o .env https://raw.githubusercontent.com/lysek01/iot-tig-lite/main/examples/.env.example
   ```
3. Edit `.env` (see [Configuration](#configuration)):
   ```bash
   nano .env
   ```
4. Start:
   ```bash
   docker compose up -d
   ```
5. Check the log – a summary of received messages is printed every minute:
   ```bash
   docker logs -f iot-tig-lite
   ```
6. Open `http://<device-ip>:3000`, log in as `admin` / `admin`.
   The **IoT Overview** dashboard shows every topic as soon as data arrive,
   the **System** dashboard shows CPU, memory, temperature and free disk space.

Without Compose:

```bash
docker run -d --name iot-tig-lite --restart unless-stopped --env-file .env \
  -p 3000:3000 -p 1883:1883 -p 9001:9001 \
  -v ./data/influxdb:/var/lib/influxdb -v ./data/grafana:/var/lib/grafana -v ./data/mosquitto:/mosquitto/data \
  lysek01/iot-tig-lite
```

## Configuration

All settings are environment variables, normally kept in `.env`.
After a change run `docker compose up -d` again.
[`examples/.env.example`](examples/.env.example) describes every option.

| Variable | Default | Meaning |
|---|---|---|
| `MQTT_BROKER` | `internal` | `internal` = built-in broker, or `tcp://host:1883`, `ssl://host:8883` |
| `MQTT_USERNAME`, `MQTT_PASSWORD` | empty | login Telegraf uses for the broker (empty = anonymous) |
| `MQTT_TOPICS` | `#` | topics to subscribe to, comma separated, wildcards `+` and `#` |
| `MQTT_FORMAT` | `auto` | `auto`, `value`, `json` or `influx` – see below |
| `INFLUXDB_DB` | `iot` | database for the data |
| `INFLUXDB_USER`, `INFLUXDB_USER_PASSWORD` | `iot`, `iot` | user with all privileges on the database (used by Telegraf and Grafana) |
| `INFLUXDB_ADMIN_USER`, `INFLUXDB_ADMIN_PASSWORD` | `admin`, `admin` | InfluxDB server administrator |
| `INFLUXDB_RETENTION` | `30d` | how long data are kept: `12h`, `7d`, `52w`, `INF`, … |
| `GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD` | `admin`, `admin` | Grafana administrator (first start only) |
| `GF_AUTH_ANONYMOUS_ENABLED` | `false` | view dashboards without login |
| `GF_*` | | any [Grafana setting](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#override-configuration-with-environment-variables) |
| `INFLUXDB_<SECTION>_<KEY>` | | any [InfluxDB setting](https://docs.influxdata.com/influxdb/v1/administration/config/) |
| `SYSTEM_METRICS` | `true` | collect CPU, memory, temperature and disk usage |
| `TZ` | `Europe/Prague` | time zone of the logs |

The InfluxDB settings (database, users, passwords, retention) are applied on **every** start,
existing data are kept. The Grafana admin password is only applied on the very first start
(change it later in the Grafana UI).

## How data are stored

| MQTT message | Stored in InfluxDB |
|---|---|
| topic `pc11/t`, payload `23.4` | measurement `mqtt`, tag `topic=pc11/t`, field `value=23.4` |
| payload `true` / `false` | field `value=1` / `value=0` |
| payload `{"temp":21.5,"hum":40}` | fields `temp=21.5`, `hum=40` |
| payload `{"a":{"b":1}}` | field `a_b=1` (nested keys joined with `_`) |
| payload `hello` | field `text="hello"` |

All numbers are stored as floats. `MQTT_FORMAT` selects which payloads are accepted:

| `MQTT_FORMAT` | Accepts |
|---|---|
| `auto` | everything above, detected per message |
| `value` | numbers and `true`/`false` only, other messages are dropped with a warning |
| `json` | JSON only |
| `influx` | [InfluxDB line protocol](https://docs.influxdata.com/influxdb/v1/write_protocols/line_protocol_tutorial/), measurement and fields come from the message; the `topic` tag is added |

### Your own chart in Grafana

*Dashboards → New → New dashboard → Add visualization → InfluxDB*, then in the query editor:

`FROM mqtt` · `WHERE topic = pc11/t` · `SELECT field(value) mean()` · `GROUP BY time($__interval)`

The same as a raw InfluxQL query:

```sql
SELECT mean("value") FROM "mqtt" WHERE "topic" = 'pc11/t' AND $timeFilter GROUP BY time($__interval)
```

## Ports and data

| Port | Service |
|---|---|
| 3000 | Grafana |
| 1883 | MQTT (built-in broker) |
| 9001 | MQTT over WebSockets (built-in broker) |
| 8086 | InfluxDB HTTP API, authentication required (not published by the example compose file) |

| Path in container | Content |
|---|---|
| `/var/lib/influxdb` | InfluxDB data |
| `/var/lib/grafana` | Grafana database (users, your dashboards) |
| `/mosquitto/data` | broker persistence |

## Advanced configuration

Every component uses its standard configuration location, so the official documentation applies.
Uncomment the matching lines in [`compose.yaml`](examples/compose.yaml).

| What | Mount | Notes |
|---|---|---|
| Mosquitto | `/mosquitto/config` | `mosquitto.conf`, passwords, ACL, certificates – same as the official `eclipse-mosquitto` image. If the directory has no `mosquitto.conf`, the default one is created there. Keep a listener on port 1883 (it may be bound to `127.0.0.1`), Telegraf uses it. |
| Telegraf, extra plugins | `/etc/telegraf/telegraf.d` | `*.conf` files are loaded in addition to the generated configuration. |
| Telegraf, full control | `/etc/telegraf/telegraf.conf` | replaces the generated configuration; the `MQTT_*` variables are then ignored. |
| InfluxDB | `/etc/influxdb/influxdb.conf` | or `INFLUXDB_<SECTION>_<KEY>` variables |
| Grafana | `/etc/grafana/grafana.ini`, `/etc/grafana/provisioning` | or `GF_*` variables. Mounting `provisioning` replaces the built-in data source and dashboards. |

The Telegraf build in this image contains only these plugins: inputs `mqtt_consumer`, `cpu`, `mem`,
`disk`, `system`, `temp`, `filecount`; output `influxdb`; parsers `value`, `influx`; processor `starlark`.

## Maintenance

```bash
docker compose pull && docker compose up -d   # update, data are kept
docker compose down                           # stop
docker logs -f iot-tig-lite                   # log
docker exec -it iot-tig-lite mosquitto_sub -t '#' -v   # watch MQTT messages
```

Old data are deleted automatically after `INFLUXDB_RETENTION`.
The example `compose.yaml` limits the container log to 30 MB.

## Building

```bash
docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -t lysek01/iot-tig-lite --push .
test/test.sh iot-tig-lite:dev                 # end-to-end test of a local image
```

Telegraf is compiled from source with only the needed plugins; InfluxDB and Grafana binaries come
from their official images, stripped of debug information, unused plugins, translations and source maps.

## Licenses

This image bundles [Grafana](https://github.com/grafana/grafana) (AGPL-3.0),
[InfluxDB 1.8](https://github.com/influxdata/influxdb/tree/1.8) (MIT),
[Telegraf](https://github.com/influxdata/telegraf) (MIT) and
[Eclipse Mosquitto](https://github.com/eclipse-mosquitto/mosquitto) (EPL-2.0 / EDL-1.0).
Their source code is available at the links above.
