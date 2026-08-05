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
