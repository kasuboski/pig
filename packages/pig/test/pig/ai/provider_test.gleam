//// Provider is a type alias — fn(List(Message), List(ToolDefinition)) -> Result(Message, AiError).
//// The compiler enforces type compatibility. No logic to test.
//// Real provider behavior tested via openai_test golden files and agent core scenarios.

import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}
