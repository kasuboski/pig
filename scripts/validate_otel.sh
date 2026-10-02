#!/usr/bin/env bash
# Run a clean local host graph, never modifying production manifests/builds.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ ${PIG_OTEL_MISE_ACTIVE:-0} != 1 ]]; then
  exec mise exec -- env PIG_OTEL_MISE_ACTIVE=1 "$0" "$@"
fi
while IFS= read -r name; do unset "$name"; done < <(compgen -e | rg '^OTEL_' || true)
command -v cc >/dev/null || {
  echo 'A C compiler is required by Pig/sqlight/esqlite. Add cc to PATH.' >&2
  exit 1
}
evidence=${PIG_OTEL_EVIDENCE_DIR:-/tmp/pig-otel-evidence/local-validation}
mkdir -p "$evidence"
evidence=$(cd "$evidence" && pwd)
export PIG_OTEL_EVIDENCE_DIR="$evidence"
work=$(mktemp -d "${TMPDIR:-/tmp}/pig-otel-validation.XXXXXXXX")
export XDG_CACHE_HOME="$work/cache"
mkdir -p "$XDG_CACHE_HOME"
printf '%s\n' "$work" > "$evidence/workdir.txt"
cleanup() {
  if [[ ${PIG_OTEL_KEEP_WORKDIR:-0} == 1 ]]; then
    echo "Retained validation workdir: $work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Paths remain the actual package graph; no upstream/cache patches or binding
# substitutions. Compare copied source to the live tree before any build IO.
(cd "$root" && tar --exclude='build' --exclude='_build' --exclude='.git' \
  --exclude='erl_crash.dump' -cf - packages scripts/validate_otel.sh \
  scripts/check_otel_warnings.awk scripts/test_otel_warning_gate.sh mise.toml) | (cd "$work" && tar -xf -)
(
  cd "$work"
  rg --files --hidden --no-ignore -g '!build' -g '!_build' -g '!.git' packages scripts mise.toml \
    | LC_ALL=C sort | while IFS= read -r file; do sha256sum "$file"; done
) > "$evidence/source.sha256"
sha256sum --check "$evidence/source.sha256" > "$evidence/source-copy-check.log"
(cd "$evidence" && sha256sum source.sha256) | tee "$evidence/source-manifest.sha256"
bash "$work/scripts/test_otel_warning_gate.sh" | tee "$evidence/warning-policy-test.log"
# Retry only explicit transient HTTP rate/service errors, never compilation or
# resolution failures. Keep every attempt; use the same isolated source graph.
retry_hex() {
  local log=$1 attempt status
  shift
  : > "$log"
  for attempt in 1 2 3 4 5; do
    if "$@" > "$work/hex-attempt.log" 2>&1; then
      cat "$work/hex-attempt.log" | tee -a "$log"
      return 0
    else
      status=$?
      cat "$work/hex-attempt.log" | tee -a "$log"
      if [[ $attempt == 5 ]] || ! rg -qi '429|too many requests|rate.limit|503|service unavailable' "$work/hex-attempt.log"; then
        return "$status"
      fi
      echo "Transient Hex failure; retry $attempt/5 in $((attempt * 30))s" | tee -a "$log"
      sleep "$((attempt * 30))"
    fi
  done
}
example="$work/packages/pig_otel/examples/local_validation"
{
  mise --version
  gleam --version
  rebar3 --version
  erl -noshell -eval '{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:format("OTP ~s / ERTS ~s~n", [string:trim(V), erlang:system_info(version)]), halt().'
  cc --version
} | tee "$evidence/versions.log"
cd "$example/host"
retry_hex "$evidence/host-build.log" rebar3 compile
cp rebar.lock "$evidence/host-rebar.lock"
# Still fatal at the final gate, but collect runtime evidence even if a
# third-party OTP29 warning fails this independent strict compilation.
mkdir -p "$work/strict-gproc"
strict_failed=0
if erlc -Wall -Werror -I _build/default/lib/gproc/include -o "$work/strict-gproc" \
  _build/default/lib/gproc/src/*.erl 2>&1 | tee "$evidence/gproc-strict.log"; then
  :
else
  strict_failed=1
fi
cd "$example"
retry_hex "$evidence/deps.log" gleam deps download
retry_hex "$evidence/build.log" gleam build --warnings-as-errors
retry_hex "$evidence/test-build.log" gleam check
# Compile real proxy test helpers in isolation. Copy only the needed test
# modules, never add the standalone package's dependency ebins to the host.
cd "$work/packages/pig_proxy"
retry_hex "$evidence/proxy-deps.log" gleam deps download
retry_hex "$evidence/proxy-build.log" gleam build --warnings-as-errors
test_ebin="$work/proxy-test-ebin"
mkdir -p "$test_ebin"
for module in support@tracing_death_harness support@tracing_harness \
  support@in_memory_transport support@runtime_harness pig_proxy_runtime_test_ffi \
  pig_proxy_trace_death_test_ffi pig_proxy_trace_test_ffi; do
  cp "build/dev/erlang/pig_proxy/ebin/$module.beam" "$test_ebin/"
done
ls "$test_ebin" > "$evidence/proxy-test-modules.log"
cd "$example"
cp manifest.toml "$evidence/manifest.toml"
{
  git -C build/packages/otel_gleam rev-parse HEAD
  git -C build/packages/otel_gleam remote get-url origin
} | tee "$evidence/binding-provenance.log"
[[ $(git -C build/packages/otel_gleam rev-parse HEAD) == 0ad06026ba0cdbdd3adfc9dd6ec882cfb8a1c2a5 ]]
[[ $(git -C build/packages/otel_gleam remote get-url origin) == https://github.com/kasuboski/otel_gleam.git ]]
[[ -z $(git -C build/packages/otel_gleam status --porcelain) ]]
rg -q 'name = "otel_gleam".*source = "git".*repo = "https://github.com/kasuboski/otel_gleam.git".*0ad06026ba0cdbdd3adfc9dd6ec882cfb8a1c2a5' manifest.toml
for package in pig pig_proxy pig_otel; do
  if rg -q '^opentelemetry(_exporter)?\s*=' "../../../$package/gleam.toml"; then
    echo "SDK/exporter leaked into production graph: $package" >&2
    exit 1
  fi
done
# Exporter dependencies start BEFORE the official SDK configuration. Direct
# test main avoids Gleam generated SDK-before-exporter application startup.
env -u PIG_RUN_OTEL_INTEGRATION erl -noshell \
  -pa build/dev/erlang/*/ebin host/_build/default/lib/*/ebin "$test_ebin" \
  -eval 'pig_otel_validation_host:bootstrap(), pig_otel_local_validation_test:main(), halt().' \
  2>&1 | tee "$evidence/unit.log"
PIG_RUN_OTEL_INTEGRATION=1 erl -noshell \
  -pa build/dev/erlang/*/ebin host/_build/default/lib/*/ebin "$test_ebin" \
  -eval 'pig_otel_validation_host:bootstrap(), pig_otel_local_validation_test:main(), halt().' \
  2>&1 | tee "$evidence/integration.log"
cd "$work/packages/pig_otel/fixtures/sdk_recording"
retry_hex "$evidence/shared-sdk-deps.log" gleam deps download
# Already inside mise's activated environment; match run.sh without a nested
# mise trust lookup on the copied root configuration.
retry_hex "$evidence/shared-sdk-build.log" gleam build --warnings-as-errors
erl -noshell -pa build/dev/erlang/*/ebin -eval '
  {ok, _} = application:ensure_all_started(pig_otel),
  ok = application:load(pig_otel_sdk_recording),
  pig_otel_sdk_recording_test:main(), halt().' \
  2>&1 | tee "$evidence/shared-sdk.log"
echo 'All local host and shared SDK runtime tests passed.' | tee "$evidence/runtime-result.log"
# The user accepts only the known Mist/Gramps Header deprecations. Logs remain
# intact; project and unexpected dependency warnings still fail this gate.
if awk -f "$work/scripts/check_otel_warnings.awk" \
  "$evidence/host-build.log" "$evidence/gproc-strict.log" \
  "$evidence/build.log" "$evidence/test-build.log" "$evidence/proxy-build.log" \
  "$evidence/shared-sdk-build.log" | tee "$evidence/warning-policy.log" \
  && [[ $strict_failed == 0 ]]; then
  echo "Local official SDK + actual OTLP validation passed (approved third-party warning exception). Evidence: $evidence" | tee "$evidence/warning-gate.log"
else
  echo 'Compiler warning gate failed (runtime evidence retained).' | tee "$evidence/warning-gate.log" >&2
  exit 1
fi
