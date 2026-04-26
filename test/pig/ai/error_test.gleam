import gleeunit
import pig/ai/error

pub fn main() -> Nil {
  gleeunit.main()
}

// --- Construction Tests ---

pub fn api_error_test() {
  let error.ApiError(message:) = error.ApiError("something broke")
  message == "something broke"
}

pub fn rate_limited_test() {
  let error.RateLimited = error.RateLimited
  True
}

pub fn timeout_test() {
  let error.Timeout = error.Timeout
  True
}

pub fn invalid_response_test() {
  let error.InvalidResponse(detail:) = error.InvalidResponse("bad json")
  detail == "bad json"
}

// --- Equality Tests ---

pub fn different_errors_not_equal_test() {
  error.RateLimited != error.Timeout
}
