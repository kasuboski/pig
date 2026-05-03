//// CLI argument parsing.

/// Returns the list of command-line arguments passed to the program.
///
/// This excludes the program name itself, returning only the arguments.
@external(erlang, "args_ffi", "get_args")
pub fn get_args() -> List(String)
