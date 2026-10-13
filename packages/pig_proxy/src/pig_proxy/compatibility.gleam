//// Responses request compatibility scoped to the selected upstream target.
//// Authentication supplies a default; explicit target and exact-model policies
//// override it. This module has no IO and never changes retry decisions.

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import pig_otel

/// Whether to forward or omit the top-level Responses prompt_cache_options.
pub type FieldPolicy {
  Preserve
  Omit
}

/// Explicit target default and exact-model overrides. None uses the supplied
/// authentication-derived default, so changing target auth does not leave stale
/// compatibility settings behind.
pub type Policy {
  Policy(default: Option(FieldPolicy), models: Dict(String, FieldPolicy))
}

/// Codex defaults to omission; API-key targets default to preservation.
pub fn codex_default(is_codex: Bool) -> FieldPolicy {
  case is_codex {
    True -> Omit
    False -> Preserve
  }
}

/// Apply policy only to Responses requests. Unaffected, malformed and non-object
/// bodies retain exact bytes. Removal preserves all other JSON values, including
/// nested fields, but may change formatting and object-key order.
pub fn apply(
  body: String,
  api: pig_otel.Api,
  model: String,
  default: FieldPolicy,
  policy: Policy,
) -> String {
  case api {
    pig_otel.Responses -> {
      let selected = case dict.get(policy.models, model) {
        Ok(override) -> override
        Error(_) ->
          case policy.default {
            Some(explicit) -> explicit
            None -> default
          }
      }
      case selected {
        Preserve -> body
        Omit -> remove_top_level(body)
      }
    }
    _ -> body
  }
}

@external(erlang, "pig_proxy_json_ffi", "omit_prompt_cache_options")
fn remove_top_level(body: String) -> String
