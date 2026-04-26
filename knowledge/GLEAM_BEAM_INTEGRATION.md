# Gleam/BEAM Integration Notes

Practical gotchas and patterns discovered while building `pig` on the Gleam → Erlang/OTP target.

---

## 1. Thin FFI, Thick Gleam

When wrapping an Erlang library (e.g., `:telemetry`), keep the FFI surface minimal — export raw primitives only (`execute`, `system_time`). Build all domain-specific logic (event names, metadata types, convenience wrappers) in **pure Gleam**. This keeps the Erlang code small, reviewable, and makes the Gleam layer testable in isolation.

**Bad:** One Erlang function per event (`emit_inference_start`, `emit_tool_stop`, ...) — duplicates event naming logic in Erlang.

**Good:** One `execute(name, measurements, metadata)` function. Gleam shapes the data.

---

## 2. `Dict(String, a)` and Atom-Keyed Maps

Gleam's `Dict(String, a)` serializes to Erlang maps with **binary keys** (`#{<<"model">> => <<"gpt-4">>}`). Many Erlang libraries (including `:telemetry`) expect **atom keys** (`#{model => <<"gpt-4">>}`). The FFI must convert. Our pattern: a small `atomize_keys/1` helper in the FFI module.

---

## 3. `pub opaque type` + `@external` = Compiler Warning

Gleam warns that `opaque` is redundant when a type has no constructors and is only constructed via `@external`. Use `pub type` for externally-constructed opaque handles — encapsulation comes from not exporting constructors, not from the `opaque` keyword.

---

## 4. Erlang Dependencies Require `rebar3`

Any Hex package with `build_tools = ["rebar3"]` or `["mix"]` needs `rebar3` on `PATH`. Declare it in `mise.toml` via the `rebar` plugin (`mise-plugins/mise-rebar`). Without it, `gleam build` fails with "Program not found: rebar3".

---

## 5. ETS-Based Test Listener for Telemetry

To assert on `:telemetry` events without `sleep()` or polling:

1. Create an ETS table (`ordered_set, public`)
2. Attach a handler that inserts `{monotonic_timestamp, event_data}` on each event
3. Read events in order with `ets:tab2list/1`
4. Detach and delete the table in cleanup

This gives deterministic, ordered event capture with zero timing dependency. See `pig/obs/listener.gleam` for the Gleam API and `pig_obs_ffi.erl` for the Erlang implementation.
