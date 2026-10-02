#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ ${PIG_SUBSCRIPTIONS_MISE_ACTIVE:-0} != 1 ]]; then
  exec mise exec -- env PIG_SUBSCRIPTIONS_MISE_ACTIVE=1 "$0" "$@"
fi
for name in "${!OTEL_@}"; do unset "$name"; done
example=packages/pig_proxy/examples/subscriptions
(cd "$example/host" && rebar3 compile)
(cd "$example" && gleam deps download && gleam build --warnings-as-errors && env -u PIG_RUN_SUBSCRIPTIONS_INTEGRATION gleam test)
# Run HTTP + OTLP wire acceptance on a plain VM. The test launches two host
# VMs (metadata and conversation) and a local protobuf receiver; this VM
# does not auto-start the OTel SDK.
mapfile -t paths < <(printf '%s\n' "$example"/build/dev/erlang/*/ebin "$example"/host/_build/default/lib/*/ebin)
args=()
for path in "${paths[@]}"; do
  [[ -d $path ]] && args+=( -pa "$path" )
done
PIG_RUN_SUBSCRIPTIONS_INTEGRATION=1 erl -noshell "${args[@]}" \
  -eval 'pig_subscriptions_acceptance_ffi:run(), halt(0).'
printf 'Subscriptions host HTTP + OTLP wire acceptance passed.\n'
