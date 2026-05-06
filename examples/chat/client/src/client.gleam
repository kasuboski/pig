import gleam/dict
import gleam/option
import gleam/result
import gleam/string

import lustre
import plinth/browser/document
import plinth/browser/element as e

import client/chat

pub fn main() {
  let init_model =
    document.query_selector("#model")
    |> result.map(e.inner_text)
    |> result.try(fn(text) {
      case text |> string.trim |> string.is_empty {
        True -> Error(Nil)
        False -> Ok(text)
      }
    })
    |> result.try(fn(_string_model) {
      Ok(chat.Model(
        current_agent: option.None,
        messages: dict.new(),
        draft_content: "",
        agents: [],
        connected: False,
      ))
    })
    |> option.from_result

  let assert Ok(_) = lustre.start(chat.chat(), "#app", init_model)
  Nil
}
