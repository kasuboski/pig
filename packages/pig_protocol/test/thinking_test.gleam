import gleam/list
import gleeunit
import pig_protocol/thinking

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn openai_effort_mapping_test() {
  let cases = [
    #(thinking.Off, "none"),
    #(thinking.Minimal, "minimal"),
    #(thinking.Low, "low"),
    #(thinking.Medium, "medium"),
    #(thinking.High, "high"),
    #(thinking.XHigh, "xhigh"),
    #(thinking.Max, "max"),
  ]

  list.each(cases, fn(test_case) {
    let #(level, expected) = test_case
    assert thinking.to_openai_effort(level) == expected
  })
}

pub fn provider_neutral_strings_round_trip_test() {
  let cases = [
    #(thinking.Off, "off"),
    #(thinking.Minimal, "minimal"),
    #(thinking.Low, "low"),
    #(thinking.Medium, "medium"),
    #(thinking.High, "high"),
    #(thinking.XHigh, "xhigh"),
    #(thinking.Max, "max"),
  ]

  list.each(cases, fn(test_case) {
    let #(level, expected) = test_case
    assert thinking.to_string(level) == expected
    assert thinking.from_string(expected) == Ok(level)
  })
}

pub fn provider_neutral_parser_rejects_unknown_values_test() {
  assert thinking.from_string("none") == Error(Nil)
  assert thinking.from_string("provider_default") == Error(Nil)
  assert thinking.from_string("unknown") == Error(Nil)
}
