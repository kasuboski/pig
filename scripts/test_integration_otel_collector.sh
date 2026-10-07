#!/usr/bin/env bash
# Opt-in real OpenTelemetry Collector acceptance; requires Docker and no credentials.
set -euo pipefail
command -v rg >/dev/null 2>&1 || {
  echo 'Required command not found: rg' >&2
  exit 1
}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
image='otel/opentelemetry-collector-contrib:0.123.0@sha256:e39311df1f3d941923c00da79ac7ba6269124a870ee87e3c3ad24d60f8aee4d2'
work=$(mktemp -d -t pig-otel-collector.XXXXXXXX)
cid=''
cleanup() {
  if [[ -n "$cid" ]]; then
    docker logs "$cid" >"$work/collector.log" 2>&1 || true
    docker rm -f "$cid" >/dev/null || true
  fi
  if [[ ${KEEP_COLLECTOR_EVIDENCE:-0} == 1 ]]; then
    printf 'Collector evidence retained at %s\n' "$work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker info >/dev/null
docker pull "$image"
docker run --rm "$image" --version
(cd packages/pig_proxy/examples/subscriptions/host && rebar3 compile)
(cd packages/pig_proxy/examples/subscriptions && gleam deps download && gleam build --warnings-as-errors && env -u PIG_RUN_SUBSCRIPTIONS_INTEGRATION gleam test)
cid=$(docker run -d --user "$(id -u):$(id -g)" \
  -p 127.0.0.1::4318 \
  -v "$root/packages/pig_proxy/examples/subscriptions/test/collector.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  -v "$work:/evidence" "$image" --config=/etc/otelcol-contrib/config.yaml)
port=$(docker port "$cid" 4318/tcp | awk -F: '{print $NF}')
endpoint="http://127.0.0.1:$port"
printf 'Official Collector OTLP HTTP base endpoint: %s\n' "$endpoint"
mapfile -t paths < <(printf '%s\n' packages/pig_proxy/examples/subscriptions/build/dev/erlang/*/ebin packages/pig_proxy/examples/subscriptions/host/_build/default/lib/*/ebin)
args=()
for path in "${paths[@]}"; do [[ -d $path ]] && args+=( -pa "$path" ); done
PIG_REAL_COLLECTOR_ENDPOINT="$endpoint" mise exec -- erl -noshell "${args[@]}" \
  -eval 'support@acceptance:run_real_collector(os:getenv("PIG_REAL_COLLECTOR_ENDPOINT")), halt(0).'
# Give the file exporter a bounded opportunity to flush its 100 ms interval.
for _ in $(seq 1 50); do [[ -s "$work/traces.jsonl" ]] && break; sleep 0.1; done
[[ -s "$work/traces.jsonl" ]]
docker logs "$cid" >"$work/collector.log" 2>&1
if rg -i '"level":"error"|Exporting failed|failed to export' "$work/collector.log"; then
  echo 'Collector reported an error' >&2
  exit 1
fi
python3 scripts/verify_otel_collector_file.py "$work/traces.jsonl"
if rg -i 'collector-acceptance-private-marker|synthetic-zai-key|synthetic-account|synthetic-signature|fake_jwt|authorization' "$work/traces.jsonl" "$work/collector.log"; then
  echo 'Unexpected private or credential field in Collector output' >&2
  exit 1
fi
printf 'Real Collector file/debug exporters verified; container removed on exit.\n'
