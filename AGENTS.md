A Gleam library for building and orchestrating agents on the BEAM. `pig` is inspired by the architecture of [pi](https://pi.dev).

High-Level Goals
*   **Composition over Configuration:** Build specialized agents by composing discrete skills and tools.
*   **Provider Agnostic:** Normalize interactions across OpenAI, Anthropic, and local models.
*   **Resilient by Default:** Leverage OTP supervision trees to ensure tool failures or API timeouts don't crash the system.
*   **Deep Observability:** Native integration with BEAM `:telemetry` for world-class tracing and debugging.
*   **Target BEAM:** No javascript platform is necessary


Related project knowledge can be found in the knowledge folder. Use this before trying to search the web.
- SPEC.md includes a high level specification of what we are building
- TESTING_STRATEGY.md includes the testing strategy for the project that MUST be followed.
- GLEAM_OVERVIEW.md is the entire gleam language tour site.
- repos/ includes git repos that provide reference e.g. the pi-mono repo is there.

Use glight for logging Examples:
```gleam
import glight.{
  alert, critical, debug, emergency, error, info, logger, notice, warning, with,
}
logger()
  |> with("key", "value")
  |> with("one", "two, buckle my shoe")
  |> with("three", "four close the door")
  |> debug("hello debug")

  logger() |> with("it's catchy", "you like it") |> info("this is the hook.")
  logger() |> with("it's catchy", "you like it") |> notice("this is the hook.")
  logger() |> with("it's catchy", "you like it") |> warning("this is the hook.")
  logger() |> with("it's catchy", "you like it") |> error("this is the hook.")
  logger()
  |> with("it's catchy", "you like it")
  |> critical("this is the hook.")
  logger() |> with("it's catchy", "you like it") |> alert("this is the hook.")
  logger()
  |> with("it's catchy", "you like it")
  |> emergency("this is the hook.")
```
