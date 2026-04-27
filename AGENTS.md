A Gleam library for building and orchestrating agents on the BEAM. `pig` is inspired by the architecture of [pi](https://pi.dev).

High-Level Goals
*   **Composition over Configuration:** Build specialized agents by composing discrete skills and tools.
*   **Provider Agnostic:** Normalize interactions across OpenAI, Anthropic, and local models.
*   **Resilient by Default:** Leverage OTP supervision trees to ensure tool failures or API timeouts don't crash the system.
*   **Deep Observability:** Native integration with BEAM `:telemetry` for world-class tracing and debugging.
*   **Target BEAM:** No javascript platform is necessary

No backwards compatibility is necessary - use the latest versions and NO deprecated methods.


Code Quality:
- Fix compiler warnings — zero warnings is the baseline
- Prefer union types over multiple related types — a single `Event` custom type with variants
  is better than six separate `FooMeta` record types. It gives exhaustiveness checking,
  pattern matching, and single-function APIs (`emit(Event)` not `emit_foo(FooMeta)`).
- Make illegal states unrepresentable — if a combination of fields shouldn't exist,
  the type system should prevent constructing it.
- Types should encode intent — a type named `Event` with `ToolStart` and `InferenceStop`
  variants is self-documenting; `Dict(String, String)` is not.

Related project knowledge can be found in the knowledge folder. Use this before trying to search the web.
- SPEC.md includes a high level specification of what we are building
- TESTING_STRATEGY.md includes the testing strategy for the project that MUST be followed.
- GLEAM_OVERVIEW.md is the entire gleam language tour site.
- repos/ includes git repos that provide reference e.g. the pi-mono repo is there.


## Observability: Telemetry vs Logging

**Two channels, two audiences. Never duplicate information across both.**

| | `:telemetry` (`pig/obs`) | `:logger` (`logging`) |
|---|---|---|
| Audience | Library users (JSONL, OTel, dashboards) | Library developers (us, debugging pig internals) |
| What | Structured events: `[:pig, :inference, :stop]` with measurements + metadata | Freeform text: HTTP transport details, config validation, internal state |
| Where | `pig/obs/events.gleam` emits; `pig/obs/terminal` and `pig/obs/session` consume | Any module, for gaps telemetry doesn't cover |
| Visibility | User-facing, always-on when handlers attached | Off by default, enabled via log level |

**Rules:**
- If telemetry covers it (inference, tool execution), do NOT also log it.
- `:logger` is for gaps: HTTP transport debugging, unexpected states, config warnings.
- `pig/obs/terminal` is a telemetry handler, not a logger.

## Logging Usage

Use the `logging` package for internal debug logging. Examples:
```gleam
import logging

logging.debug("HTTP POST /v1/chat/completions -> 429, retrying")
logging.warning("Config has no base_url, using default")
logging.error("Provider returned malformed JSON")
```

## Gleam Idioms & Conventions

### 1. Conventions (Mandatory Standards)

#### Naming
- **Variables, Functions, and Modules**: Use `snake_case` (e.g., `calculate_total`, `my_module.gleam`).
- **Constants**: Use `snake_case`. Gleam does *not* use SCREAMING_SNAKE_CASE (e.g., `const max_retries = 5`).
- **Types and Constructors**: Use `PascalCase` (e.g., `type UserAccount { AdminUser }`).

#### Formatting
- Always use 2 spaces for indentation.
- Assume code will be formatted with `gleam format`.
- Leave a blank line between top-level definitions.

#### Documentation
- Use `///` to document public functions and types. This generates HTML documentation.
- Use `////` at the top of a file to document the module itself.
- Use standard `//` for internal implementation comments.

#### Imports
- **Prefer Qualified Imports**: Avoid bringing functions directly into scope. Use `list.map` instead of importing `map` unqualified. 
- **Unqualified Types are OK**: It is idiomatic to import types unqualified (e.g., `import gleam/option.{type Option, Some, None}`).

### 2. Patterns (Idiomatic Gleam)

#### The `use` Expression
Use `use` to flatten nested callbacks, especially for `Result` types (replacing `result.try`).

**Do this:**
```gleam
use user <- result.try(get_user(id))
use profile <- result.try(get_profile(user))
Ok(profile)
```

**Instead of this:**
```gleam
case get_user(id) {
  Ok(user) -> {
    case get_profile(user) -> {
      Ok(profile) -> Ok(profile)
      Error(e) -> Error(e)
    }
  }
  Error(e) -> Error(e)
}
```

#### The Pipe Operator (`|>`)
Use pipes to chain function calls and show the flow of data.
*Remember: The piped value is always passed as the **first** argument to the next function.*

```gleam
" Hello "
|> string.trim
|> string.lowercase
```

*Note: Do not use pipes for a single function call (e.g., `x |> do_thing` is an anti-pattern; just use `do_thing(x)`).*

#### Opaque Types
When building libraries or boundaries, use `opaque type` to prevent users from manually constructing or pattern-matching on internal data structures, forcing them to use your provided API.

#### Make Invalid States Unrepresentable
Prefer custom types over built-in primitives to represent states.
**Example**: Instead of `is_open: Bool`, use `type DoorState { Open Closed }`.
