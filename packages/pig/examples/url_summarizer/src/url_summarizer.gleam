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

import envoy
import gleam/io
import gleam/result
import gleam/string
import pig
import pig/openai
import pig/run_error
import pig/tool/web_fetch
import pig_protocol/error
import pig_protocol/message
import pig_protocol/thinking

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
  let provider = openai.provider_with_base_url(api_key(), model(), base_url())

  let cfg =
    pig.new(provider.call)
    |> pig.with_model("url_summarizer")
    |> pig.with_thinking_level(thinking.Off)
    |> pig.with_system_prompt(
      "You summarize web pages. When given a URL, use the web_fetch tool "
      <> "to retrieve it, then provide a concise summary of the page content. "
      <> "Use bullet points. Focus on the key takeaways.",
    )
    |> pig.with_tool(web_fetch.tool())
    |> pig.with_terminal_output()

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
    Error(run_error.Inference(error.Timeout)) -> {
      io.println("\n⚠ Timed out waiting for the model to respond.")
      io.println("Try a faster model or increase the timeout.")
    }
    Error(run_error.Inference(error.ApiError(msg))) -> {
      io.println("\n⚠ API error: " <> msg)
    }
    Error(run_error.Inference(error.RateLimited)) -> {
      io.println("\n⚠ Rate limited — wait a moment and try again.")
    }
    Error(run_error.Inference(error.InvalidResponse(detail))) -> {
      io.println("\n⚠ Invalid response from provider: " <> detail)
    }
    Error(run_error.Session(session_error)) -> {
      io.println("\n⚠ Session error: " <> string.inspect(session_error))
    }
    Error(run_error.Runtime(message)) -> {
      io.println("\n⚠ Runtime error: " <> message)
    }
  }

  pig.stop(agent)
}
