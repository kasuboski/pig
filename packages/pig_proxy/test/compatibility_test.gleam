import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import pig_otel
import pig_proxy/compatibility

fn check(
  body: String,
  api: pig_otel.Api,
  model: String,
  default: compatibility.FieldPolicy,
  policy: compatibility.Policy,
  expected: String,
  exact_bytes: Bool,
) {
  let actual = compatibility.apply(body, api, model, default, policy)
  case exact_bytes {
    True -> should.equal(actual, expected)
    False ->
      should.equal(
        json.parse(actual, decode.dynamic),
        json.parse(expected, decode.dynamic),
      )
  }
}

fn inherited() -> compatibility.Policy {
  compatibility.Policy(None, dict.new())
}

pub fn removal_preserves_all_unrelated_json_values_test() {
  check(
    "{\"model\":\"x\",\"prompt_cache_options\":{\"mode\":\"explicit\"},\"prompt_cache_key\":\"key\",\"prompt_cache_retention\":\"24h\",\"nested\":{\"prompt_cache_options\":1},\"input\":[{\"content\":\"é \\\" prompt_cache_options\"}],\"values\":[null,true,false,9007199254740993,1.25]}",
    pig_otel.Responses,
    "x",
    compatibility.Omit,
    inherited(),
    "{\"model\":\"x\",\"prompt_cache_key\":\"key\",\"prompt_cache_retention\":\"24h\",\"nested\":{\"prompt_cache_options\":1},\"input\":[{\"content\":\"é \\\" prompt_cache_options\"}],\"values\":[null,true,false,9007199254740993,1.25]}",
    False,
  )
}

pub fn absent_malformed_and_non_object_bodies_keep_exact_bytes_test() {
  list.each(
    [
      " { \"model\" : \"x\" } ",
      "{broken",
      "null",
      "[1,2]",
      "\"prompt_cache_options\"",
      "{\"prompt_cache_options\":{}, trailing}",
      "{\"nested\":{\"prompt_cache_options\":true}}",
    ],
    fn(body) {
      check(
        body,
        pig_otel.Responses,
        "x",
        compatibility.Omit,
        inherited(),
        body,
        True,
      )
    },
  )
}

pub fn all_top_level_value_shapes_are_removed_test() {
  list.each(["{}", "null", "true", "1", "\"text\"", "[1,2]"], fn(value) {
    check(
      "{\"prompt_cache_options\":" <> value <> "}",
      pig_otel.Responses,
      "x",
      compatibility.Omit,
      inherited(),
      "{}",
      False,
    )
  })
}

pub fn other_api_and_preserve_keep_exact_bytes_test() {
  let body = " {\"prompt_cache_options\": {\"mode\":\"explicit\"} } "
  check(
    body,
    pig_otel.ChatCompletions,
    "x",
    compatibility.Omit,
    inherited(),
    body,
    True,
  )
  check(
    body,
    pig_otel.Responses,
    "x",
    compatibility.Preserve,
    inherited(),
    body,
    True,
  )
}

pub fn exact_model_overrides_target_and_auth_defaults_test() {
  let body = " {\"prompt_cache_options\":{},\"model\":\"x\"} "
  let preserve_x =
    compatibility.Policy(
      Some(compatibility.Omit),
      dict.from_list([#("x", compatibility.Preserve)]),
    )
  check(
    body,
    pig_otel.Responses,
    "x",
    compatibility.Omit,
    preserve_x,
    body,
    True,
  )
  check(
    body,
    pig_otel.Responses,
    "x-other",
    compatibility.Preserve,
    preserve_x,
    "{\"model\":\"x\"}",
    False,
  )
  let omit_x =
    compatibility.Policy(
      Some(compatibility.Preserve),
      dict.from_list([#("x", compatibility.Omit)]),
    )
  check(
    body,
    pig_otel.Responses,
    "x",
    compatibility.Preserve,
    omit_x,
    "{\"model\":\"x\"}",
    False,
  )
  check(body, pig_otel.Responses, "X", compatibility.Omit, omit_x, body, True)
}
