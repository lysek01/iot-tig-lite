#!/bin/bash
# End-to-end test of an iot-tig-lite image.
#   test/test.sh [image] [platform]
#   e.g. test/test.sh iot-tig-lite:dev linux/arm/v7
#
# Needs only Docker. Uses its own containers, network and temp directory.

set -uo pipefail

IMAGE=${1:-iot-tig-lite:dev}
PLATFORM=${2:-}
NAME=itl-test
NET=itl-test-net
BROKER=itl-test-broker
DATA=$(mktemp -d)
PASS=0; FAILED=0
PLAT=()
[ -n "$PLATFORM" ] && PLAT=(--platform "$PLATFORM")

ok()    { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()   { echo "  FAIL  $*"; FAILED=$((FAILED+1)); }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
equals() { local desc=$1 got=$2 want=$3; if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (got '$got', want '$want')"; fi; }

cleanup() {
  docker rm -f $NAME $BROKER >/dev/null 2>&1
  docker network rm $NET >/dev/null 2>&1
  docker run --rm -v "$DATA:/d" alpine sh -c 'rm -rf /d/*' >/dev/null 2>&1
  rm -rf "$DATA"
}
trap cleanup EXIT

start() { # start <env...>
  docker rm -f $NAME >/dev/null 2>&1
  local envs=()
  for e in "$@"; do envs+=(-e "$e"); done
  docker run -d --name $NAME "${PLAT[@]}" --network $NET "${envs[@]}" \
    -v "$DATA/influxdb:/var/lib/influxdb" -v "$DATA/grafana:/var/lib/grafana" -v "$DATA/mosquitto:/mosquitto/data" \
    "$IMAGE" >/dev/null
  local t0=$SECONDS
  until docker logs $NAME 2>&1 | grep -q '\[iot-tig-lite\] ready'; do
    if [ -z "$(docker ps -q -f name=^$NAME$)" ]; then echo "container exited:"; docker logs $NAME 2>&1 | tail -30; return 1; fi
    [ $((SECONDS - t0)) -gt 900 ] && { echo "timeout"; docker logs $NAME 2>&1 | tail -30; return 1; }
    sleep 2
  done
  echo "  (ready after $((SECONDS - t0)) s)"
}

x()   { docker exec -i $NAME "$@"; }
jqc() { x jq "$@"; }
pub() { x mosquitto_pub -h 127.0.0.1 -t "$1" -m "$2"; }
influxq() { # influxq <db> <user> <pass> <query>
  x curl -sf -G http://127.0.0.1:8086/query -u "$2:$3" --data-urlencode "db=$1" --data-urlencode "q=$4"
}
field() { # field <db> <user> <pass> <measurement> <topic> <field> -> last value
  influxq "$1" "$2" "$3" "SELECT last(\"$6\") FROM \"$4\" WHERE \"topic\" = '$5'" | jqc -c '.results[0].series[0].values[0][1]'
}
graf() { x curl -sf -u admin:admin "http://127.0.0.1:3000$1"; }
dsq() { # run an InfluxQL query through Grafana like a dashboard panel does
  local body
  body=$(jqc -nc --arg q "$1" --arg f "${2:-time_series}" '{from:"now-1h",to:"now",queries:[{refId:"A",datasource:{uid:"iot-tig-lite-influxdb"},rawQuery:true,query:$q,resultFormat:$f,intervalMs:10000,maxDataPoints:500}]}')
  x curl -sf -u admin:admin -H 'Content-Type: application/json' -X POST http://127.0.0.1:3000/api/ds/query -d "$body"
}

docker network create $NET >/dev/null

# ---------------------------------------------------------------------
echo "== 1. defaults: internal broker, MQTT_FORMAT=auto"
start || exit 1
pub t/num "23.4";  pub t/int "23";  pub t/neg " -1.5e2 ";  pub t/bool "true"
pub t/text "hello world"
pub t/json '{"temp":21.5,"hum":40,"nested":{"a":1},"arr":[1,2],"s":"ok","n":"12.5","flag":false}'
pub t/badjson '{abc'
sleep 12
D="iot iot iot"
equals "number -> value"          "$(field $D mqtt t/num value)" "23.4"
equals "int -> value (float)"     "$(field $D mqtt t/int value)" "23"
equals "-1.5e2 -> value"          "$(field $D mqtt t/neg value)" "-150"
equals "true -> 1"                "$(field $D mqtt t/bool value)" "1"
equals "text -> text field"       "$(field $D mqtt t/text text)" '"hello world"'
equals "json temp"                "$(field $D mqtt t/json temp)" "21.5"
equals "json nested_a"            "$(field $D mqtt t/json nested_a)" "1"
equals "json arr_1"               "$(field $D mqtt t/json arr_1)" "2"
equals "json string s"            "$(field $D mqtt t/json s)" '"ok"'
equals "json numeric string n"    "$(field $D mqtt t/json n)" "12.5"
equals "json false -> 0"          "$(field $D mqtt t/json flag)" "0"
equals "invalid json -> text"     "$(field $D mqtt t/badjson text)" '"{abc"'
equals "retention 30d"            "$(influxq _internal admin admin 'SHOW RETENTION POLICIES ON iot' | jqc -r '.results[0].series[0].values[0][1]')" "720h0m0s"
check  "auth required on :8086"   bash -c "! docker exec $NAME curl -sf -G http://127.0.0.1:8086/query --data-urlencode 'q=SHOW DATABASES'"
equals "grafana datasource health" "$(graf /api/datasources/uid/iot-tig-lite-influxdb/health | jqc -r .status)" "OK"
equals "grafana dashboards"       "$(graf '/api/search?tag=iot-tig-lite' | jqc -r '[.[].title] | sort | join(",")')" "IoT Overview,System"
equals "chart query: mean(*) with text fields" \
  "$(dsq 'SELECT mean(*) FROM /.*/ WHERE "topic" =~ /^t\/json$/ AND $timeFilter GROUP BY time($__interval) fill(none)' | jqc -r '[.results.A.frames[].schema.name] | length > 3')" "true"
equals "table query: one row per topic" \
  "$(dsq 'SELECT last(*) FROM /.*/ WHERE "topic" =~ /^t\//  AND $timeFilter GROUP BY "topic"' table | jqc -r '.results.A.frames[0].data.values[0] | length')" "7"
echo "  (waiting for system metrics)"; sleep 35
equals "system metrics present"   "$(influxq iot iot iot 'SHOW MEASUREMENTS' | jqc -c '[.results[0].series[0].values[][0]] | (index("cpu") != null and index("mem") != null and index("disk") != null and index("influxdb_size") != null)')" "true"
check  "no errors in logs"        bash -c "! docker logs $NAME 2>&1 | grep -E 'E!|ERROR|panic|lvl=eror|level=error'"
echo "  --- warnings/errors in log ---"; docker logs $NAME 2>&1 | grep -E 'E!|W!|ERROR|WARN|level=(warn|error)' | head -15

# ---------------------------------------------------------------------
echo "== 2. change settings on existing data (course-like settings)"
start INFLUXDB_DB=bss INFLUXDB_USER=bss INFLUXDB_USER_PASSWORD=bss209BSS "INFLUXDB_ADMIN_PASSWORD=S3cr\"et'pw" \
      INFLUXDB_RETENTION=7d 'MQTT_TOPICS=pc11/#' MQTT_FORMAT=value SYSTEM_METRICS=false || exit 1
pub pc11/t "22.1"; pub pc12/t "99"; pub pc11/bad "abc"
sleep 12
B="bss bss bss209BSS"
equals "new db/user works"        "$(field $B mqtt pc11/t value)" "22.1"
equals "topic filter (pc12 ignored)" "$(field $B mqtt pc12/t value)" "null"
equals "value mode drops text"    "$(field $B mqtt pc11/bad text)" "null"
equals "old data kept in db iot"  "$(field $D mqtt t/num value)" "23.4"
check  "admin password changed"   influxq _internal admin "S3cr\"et'pw" 'SHOW USERS'
equals "retention 7d"             "$(influxq bss bss bss209BSS 'SHOW RETENTION POLICIES ON bss' | jqc -r '.results[0].series[0].values[0][1]')" "168h0m0s"
equals "grafana datasource follows" "$(graf /api/datasources/uid/iot-tig-lite-influxdb/health | jqc -r .status)" "OK"
check  "warning for dropped value" bash -c "docker logs $NAME 2>&1 | grep -q \"does not match MQTT_FORMAT=value\""

# ---------------------------------------------------------------------
echo "== 3. external broker with login, MQTT_FORMAT=influx"
docker rm -f $BROKER >/dev/null 2>&1
docker run -d --name $BROKER --network $NET eclipse-mosquitto:2 sh -c '
  printf "listener 1883\nallow_anonymous false\npassword_file /mosquitto/config/passwd\n" > /mosquitto/config/m.conf
  mosquitto_passwd -b -c /mosquitto/config/passwd student secret
  chown mosquitto:mosquitto /mosquitto/config/passwd; chmod 0600 /mosquitto/config/passwd
  exec mosquitto -c /mosquitto/config/m.conf' >/dev/null
sleep 2
start MQTT_BROKER=tcp://$BROKER:1883 MQTT_USERNAME=student MQTT_PASSWORD=secret MQTT_FORMAT=influx 'MQTT_TOPICS=lab/#' || exit 1
check  "internal broker not started" bash -c "! docker exec $NAME pgrep -x mosquitto"
sleep 3
docker exec $BROKER mosquitto_pub -u student -P secret -t lab/env -m 'env,room=lab temp=24.5,hum=39i'
sleep 12
equals "line protocol stored"     "$(field $D env lab/env temp)" "24.5"
check  "healthcheck ok"           x healthcheck

# ---------------------------------------------------------------------
echo "== 4. invalid configuration gives a clear error"
docker rm -f $NAME >/dev/null
out=$(docker run --rm "${PLAT[@]}" -e MQTT_BROKER=192.168.1.100 "$IMAGE" 2>&1)
check  "bad MQTT_BROKER rejected" grep -q "MQTT_BROKER='192.168.1.100' is not valid" <<<"$out"

echo
echo "RESULT: $PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
