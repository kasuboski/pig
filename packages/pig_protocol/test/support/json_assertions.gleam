//// Shared JSON request assertions for protocol codec tests.

import gleam/dynamic/decode
import gleam/json

/// Return whether a JSON document contains a value at the given object path.
pub fn has_path(body: String, path: List(String)) -> Bool {
  case json.parse(body, decode.at(path, decode.dynamic)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Return whether a JSON document omits the given object path.
pub fn omits_path(body: String, path: List(String)) -> Bool {
  !has_path(body, path)
}
