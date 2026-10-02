//// Centralized pure verifier-contract harness. Synthetic normalized values
//// here test the verifier only; they are never Pig acceptance evidence.

@external(erlang, "pig_otel_validation_test_ffi", "check")
pub fn check_verifier(case_name: String) -> Nil
