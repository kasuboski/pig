//// URL Summarizer — an example pig agent that fetches and summarizes web pages.
////
//// The agent uses the built-in `web_fetch` tool to retrieve a URL,
//// then summarizes the page content in plain language.
////
//// ## Running
////
//// Set environment variables for your OpenAI-compatible provider:
////
////   OPENAI_COMPAT_BASE_URL=http://localhost:11434/v1
////   OPENAI_COMPAT_API_KEY=ollama
////   OPENAI_COMPAT_MODEL=llama3
////
//// Then:
////
////   cd examples/url_summarizer
////   gleam run

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some, None}
import gleam/result
import gleam/dynamic/decode
import gleam/json
import gleam/string
import pig
import pig/ai/error
import pig/ai/message
import pig/ai/openai
import pig/obs/events.{type Event}
import pig/obs/listener
import pig/tool/web_fetch
import envoy

// ── Config ───────────────────────────────────────────────────────────

fn base_url() -> String {
  envoy.get("OPENAI_COMPAT_BASE_URL")
  |> result.unwrap("http://localhost:11434/v1")
}

fn api_key() -> String {
  envoy.get("OPENAI_COMPAT_API_KEY")
  |> result.unwrap("ollama")
}

fn model() -> String {
  envoy.get("OPENAI_COMPAT_MODEL")
  |> result.unwrap("llama3")
}

// ── Main ─────────────────────────────────────────────────────────────

pub fn main() {
  let telemetry = listener.attach()

  let provider =
    openai.provider_with_base_url(api_key(), model(), base_url())

  let cfg =
    pig.new(provider.call)
    |> pig.with_model("url_summarizer")
    |> pig.with_system_prompt(
      "You summarize web pages. When given a URL, use the web_fetch tool "
        <> "to retrieve it, then provide a concise summary of the page content. "
        <> "Use bullet points. Focus on the key takeaways.",
    )
    |> pig.with_tool(web_fetch.tool())

  let assert Ok(agent) = pig.start(cfg)

  let url = "https://gleam.run/news/"

  io.println("=== URL Summarizer ===")
  io.println("Model: " <> model())
  io.println("Provider: " <> base_url())
  io.println("URL: " <> url)
  io.println("")

  let result =
    pig.run_with_timeout(
      agent,
      "Summarize the latest Gleam news from this page: " <> url,
      120_000,
    )

  case result {
    Ok(message.Assistant(content:, ..)) -> {
      io.println("\n=== Summary ===\n")
      io.println(content)
    }
    Ok(other) -> {
      io.println("\n⚠ Unexpected response:")
      io.println(string.inspect(other))
    }
    Error(error.Timeout) -> {
      io.println("\n⚠ Timed out waiting for the model to respond.")
      io.println("Try a faster model or increase the timeout.")
    }
    Error(error.ApiError(msg)) -> {
      io.println("\n⚠ API error: " <> msg)
    }
    Error(error.RateLimited) -> {
      io.println("\n⚠ Rate limited — wait a moment and try again.")
    }
    Error(error.InvalidResponse(detail)) -> {
      io.println("\n⚠ Invalid response from provider: " <> detail)
    }
  }

  // Collect and display telemetry
  let events = listener.get_events(telemetry)
  listener.detach(telemetry)

  io.println("\n=== How the agent decided ===\n")
  print_timeline(events)

  pig.stop(agent)
}

// ── Telemetry Formatting ─────────────────────────────────────────────

fn print_timeline(events: List(Event)) -> Nil {
  let _ =
    events
    |> list.index_map(fn(event, i) {
      let label = format_timeline_event(event)
      io.println(int.to_string(i + 1) <> ". " <> label)
    })
  Nil
}

fn format_timeline_event(event: Event) -> String {
  case event {
    events.InferenceStart(model:, message_count:) -> {
      "🧠 Model call ("
        <> model
        <> ", "
        <> int.to_string(message_count)
        <> " messages)"
    }
    events.InferenceStop(
      duration_ms:,
      input_tokens:,
      output_tokens:,
      finish_reason:,
      ..
    ) -> {
      let secs = int.to_string(duration_ms / 1000) <> "s"
      let tokens = case input_tokens, output_tokens {
        Some(inp), Some(out) ->
          " (" <> int.to_string(inp) <> "→" <> int.to_string(out) <> " tokens)"
        _, _ -> ""
      }
      let reason = case finish_reason {
        Some(r) -> " [" <> r <> "]"
        None -> ""
      }
      "🧠 Response " <> secs <> tokens <> reason
    }
    events.InferenceException(error_type:, ..) -> {
      "🧠 Inference failed: " <> error_type
    }
    events.ToolStart(tool_name:, arguments_json:, ..) -> {
      let args_label = format_tool_args(tool_name, arguments_json)
      "🔧 Called " <> tool_name <> args_label
    }
    events.ToolStop(tool_name:, duration_ms:, result:, ..) -> {
      let args_label = format_tool_args(tool_name, result)
      let secs = int.to_string(duration_ms / 1000) <> "s"
      "🔧 " <> tool_name <> args_label <> " done (" <> secs <> ")"
    }
    events.ToolException(tool_name:, arguments_json:, ..) -> {
      let args_label = format_tool_args(tool_name, arguments_json)
      "🔧 " <> tool_name <> args_label <> " failed"
    }
  }
}

fn format_tool_args(tool_name: String, arguments_json: String) -> String {
  case tool_name {
    "web_fetch" -> {
      case
        json.parse(from: arguments_json, using: decode.field("url", decode.string, decode.success))
      {
        Ok(url) -> "(" <> url <> ")"
        Error(_) -> ""
      }
    }
    _ -> ""
  }
}
