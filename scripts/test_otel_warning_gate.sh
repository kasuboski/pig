#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pig-otel-warning-check.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
checks=0

check() {
  local name=$1 expected=$2 actual
  shift 2
  "$@" > "$work/input.log"
  if awk -f "$root/scripts/check_otel_warnings.awk" "$work/input.log" > "$work/result.log"; then
    actual=0
  else
    actual=1
  fi
  if [[ $actual != "$expected" ]]; then
    echo "Warning gate regression: $name (expected $expected, got $actual)" >&2
    exit 1
  fi
  checks=$((checks + 1))
}

deprecation() {
  printf 'warning: Deprecated type used\n    location: %s:16:17\n16 | headers: List(%s),\n\nIt was deprecated with this message: %s\n\n' \
    "$1" "${3:-Header}" "${2:-Use #(String, String) instead}"
}

mixed_warnings() {
  deprecation /tmp/example/build/packages/mist/src/mist/internal/encoder.gleam
  printf 'warning: Unused variable\n'
}

incomplete_warning() {
  printf 'warning: Deprecated type used\n'
}

check no_warnings 0 printf 'Compiling pig\n'
for path in gramps/src/gramps/http mist/src/mist/internal/encoder \
  mist/src/mist/internal/http2 mist/src/mist/internal/http2/stream; do
  check "$path" 0 deprecation "/tmp/example/build/packages/$path.gleam"
done
check project_warning 1 deprecation /tmp/example/packages/pig/src/pig.gleam
check unrelated_dependency 1 deprecation /tmp/example/build/packages/other/src/http.gleam
check different_deprecation 1 deprecation /tmp/example/build/packages/mist/src/mist/internal/encoder.gleam 'Use something else'
check different_type 1 deprecation /tmp/example/build/packages/mist/src/mist/internal/encoder.gleam 'Use #(String, String) instead' Credential
check mixed_warnings 1 mixed_warnings
check incomplete_warning 1 incomplete_warning
check erlang_warning 1 printf 'source.erl:10: Warning: unused variable\n'
printf 'PASS compiler warning policy: %d checks\n' "$checks"
