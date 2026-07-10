//// Shell command execution via Erlang os:cmd.

import gleam/string

@external(erlang, "shell_ffi", "run")
fn do_run(cmd: String) -> Result(String, Nil)

pub fn run(command: String, dir: String) -> Result(String, String) {
  // Quote the directory path and escape any single quotes within it
  let escaped_dir = string.replace(dir, "'", "'\\''")
  let full_cmd = "cd '" <> escaped_dir <> "' && " <> command
  case do_run(full_cmd) {
    Ok(output) -> Ok(output)
    Error(Nil) -> Error("Failed to run command: " <> command)
  }
}
