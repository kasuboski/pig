#!/bin/sh
set -eu

case "${1:-host}" in
  host)
    # Bare erl preserves the host's explicit SDK/exporter startup ordering.
    exec erl -noshell -pa /app/gleam/*/ebin /app/otel/*/ebin \
      -eval 'subscriptions@host:main().'
    ;;
  login)
    export PIG_CODEX_LOGIN_BROWSER=0
    exec erl -noshell -pa /app/gleam/*/ebin /app/otel/*/ebin \
      -eval 'application:ensure_all_started(pig_proxy), pig_proxy@codex_login:main(), halt(0).'
    ;;
  *) exec "$@" ;;
esac
