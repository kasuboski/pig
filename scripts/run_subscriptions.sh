#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ ${PIG_SUBSCRIPTIONS_MISE_ACTIVE:-0} != 1 ]]; then
  exec mise exec -- env PIG_SUBSCRIPTIONS_MISE_ACTIVE=1 "$0" "$@"
fi
example=packages/pig_proxy/examples/subscriptions
(cd "$example/host" && rebar3 compile)
(cd "$example" && gleam deps download && gleam build --warnings-as-errors)
exec erl -noshell -pa "$example"/build/dev/erlang/*/ebin "$example"/host/_build/default/lib/*/ebin \
  -eval 'subscriptions@host:main().' -extra "$@"
