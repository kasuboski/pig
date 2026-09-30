#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mise exec -- gleam build --warnings-as-errors
# Load the fixture without auto-starting its dev SDK before configuration.
mise exec -- erl -noshell -pa build/dev/erlang/*/ebin -eval '
  {ok, _} = application:ensure_all_started(pig_otel),
  ok = application:load(pig_otel_sdk_recording),
  pig_otel_sdk_recording_test:main(),
  halt().'
