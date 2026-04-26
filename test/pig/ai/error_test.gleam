//// AiError is a simple custom type with no logic to test.
//// The compiler enforces construction and structural equality.
//// Behavioral tests (error mapping, propagation) live in http_test and openai_test.

import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}
