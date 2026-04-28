//// Code Reviewer — an example pig agent that reviews a diff.
////
//// The agent has access to a fake in-memory "repo" via `list_files`
//// and `read_file` tools. It receives a diff in the prompt and
//// autonomously decides which surrounding files to read for context
//// before producing a review.
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
////   cd examples/code_reviewer
////   gleam run

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{Some, None}
import gleam/result
import gleam/string
import jscheam/schema
import pig
import pig/ai/error
import pig/ai/message
import pig/ai/openai
import pig/ai/tool_definition
import pig/obs/events.{type Event}
import pig/obs/listener
import pig/tool
import envoy

// ── Fake Filesystem ──────────────────────────────────────────────────
// A hardcoded in-memory repo for the agent to explore.

fn fake_repo() -> dict.Dict(String, String) {
  dict.from_list([
    #(
      "src/auth/login.gleam",
      "import gleam/http/request\n"
        <> "import gleam/json\n"
        <> "import app/session\n"
        <> "import app/permissions\n"
        <> "\n"
        <> "pub fn handle_login(req: request.Request(String)) {\n"
        <> "  let assert Ok(body) = json.parse(req.body)\n"
        <> "  let username = body.username\n"
        <> "  let password = body.password\n"
        <> "  case verify_credentials(username, password) {\n"
        <> "    Ok(user) -> {\n"
        <> "      let token = session.create_token(user.id)\n"
        <> "      json.object([#(\"token\", json.string(token))])\n"
        <> "    }\n"
        <> "    Error(_) -> {\n"
        <> "      let _ = permissions.log_failed_attempt(username)\n"
        <> "      json.object([#(\"error\", json.string(\"unauthorized\"))])\n"
        <> "    }\n"
        <> "  }\n"
        <> "}\n"
        <> "\n"
        <> "fn verify_credentials(user: String, pass: String) {\n"
        <> "  todo\n"
        <> "}",
    ),
    #(
      "src/auth/session.gleam",
      "import gleam/erlang/process\n"
        <> "import gleam/otp/actor\n"
        <> "\n"
        <> "pub fn create_token(user_id: Int) -> String {\n"
        <> "  // TODO: use proper JWT signing\n"
        <> "  \"token_\" <> int.to_string(user_id)\n"
        <> "}\n"
        <> "\n"
        <> "pub fn validate_token(token: String) -> Result(Int, Nil) {\n"
        <> "  case string.split(token, on: \"_\") {\n"
        <> "    [\"token\", id_str] -> {\n"
        <> "      let assert Ok(id) = int.parse(id_str)\n"
        <> "      Ok(id)\n"
        <> "    }\n"
        <> "    _ -> Error(Nil)\n"
        <> "  }\n"
        <> "}",
    ),
    #(
      "src/auth/permissions.gleam",
      "import gleam/io\n"
        <> "import gleam/dict\n"
        <> "\n"
        <> "pub fn log_failed_attempt(username: String) -> Nil {\n"
        <> "  io.println(\"Failed login attempt for: \" <> username)\n"
        <> "}\n"
        <> "\n"
        <> "pub fn check_permission(user_id: Int, action: String) -> Bool {\n"
        <> "  let roles = get_roles(user_id)\n"
        <> "  case action {\n"
        <> "    \"read\" -> True\n"
        <> "    \"write\" -> list.member(roles, \"editor\")\n"
        <> "    \"admin\" -> list.member(roles, \"admin\")\n"
        <> "    _ -> False\n"
        <> "  }\n"
        <> "}\n"
        <> "\n"
        <> "fn get_roles(user_id: Int) -> List(String) {\n"
        <> "  todo\n"
        <> "}",
    ),
    #(
      "src/middleware.gleam",
      "import gleam/http/response\n"
        <> "import gleam/http/request\n"
        <> "import app/auth/session\n"
        <> "\n"
        <> "pub fn require_auth(\n"
        <> "  req: request.Request(String),\n"
        <> "  next: fn(request.Request(String)) -> response.Response(String),\n"
        <> ") -> response.Response(String) {\n"
        <> "  case request.get_header(req, \"authorization\") {\n"
        <> "    Ok(token) -> {\n"
        <> "      case session.validate_token(token) {\n"
        <> "        Ok(user_id) -> next(req)\n"
        <> "        Error(_) -> response.new(401)\n"
        <> "      }\n"
        <> "    }\n"
        <> "    Error(_) -> response.new(401)\n"
        <> "  }\n"
        <> "}",
    ),
    #(
      "src/app/router.gleam",
      "import gleam/http.{Get, Post}\n"
        <> "import gleam/http/request\n"
        <> "import gleam/http/response\n"
        <> "import app/auth/login\n"
        <> "import app/middleware\n"
        <> "import app/handlers/dashboard\n"
        <> "\n"
        <> "pub fn handle(req: request.Request(String)) {\n"
        <> "  case request.method(req), req.path {\n"
        <> "    Post, [\"api\", \"login\"] -> login.handle_login(req)\n"
        <> "    Get, [\"api\", \"dashboard\"] -> {\n"
        <> "      let req = middleware.require_auth(req, fn(r) { r })\n"
        <> "      dashboard.show(r)\n"
        <> "    }\n"
        <> "    _, _ -> response.new(404)\n"
        <> "  }\n"
        <> "}",
    ),
  ])
}

// ── Tool Definitions ─────────────────────────────────────────────────

fn list_files_tool() -> tool.Tool {
  let repo = fake_repo()
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "list_files",
      description:
        "List all file paths in the repository. "
        <> "Use this to discover what files exist before reading them.",
      parameters: schema.object([]),
    ),
    handler: fn(_args) {
      let paths =
        repo
        |> dict.keys()
        |> string.join("\n")
      Ok(json.string(paths))
    },
  )
}

fn read_file_tool() -> tool.Tool {
  let repo = fake_repo()
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "read_file",
      description:
        "Read the full contents of a file by its path. "
        <> "Use this to inspect surrounding code for context.",
      parameters: schema.object([
        schema.prop("path", schema.string()),
      ]),
    ),
    handler: fn(args) {
      case
        decode.run(args, decode.field("path", decode.string, decode.success))
      {
        Ok(path) -> {
          case dict.get(repo, path) {
            Ok(content) -> Ok(json.string(content))
            Error(Nil) ->
              Error(tool.ToolError(
                message: "File not found: " <> path,
              ))
          }
        }
        Error(_) ->
          Error(tool.ToolError(
            message: "Invalid arguments: expected {\"path\": \"<file-path>\"}",
          ))
      }
    },
  )
}

// ── Diff to Review ───────────────────────────────────────────────────

fn diff() -> String {
  "diff --git a/src/auth/login.gleam b/src/auth/login.gleam
--- a/src/auth/login.gleam
+++ b/src/auth/login.gleam
@@ -5,11 +5,10 @@
 pub fn handle_login(req: request.Request(String)) {
   let assert Ok(body) = json.parse(req.body)
   let username = body.username
   let password = body.password
-  case verify_credentials(username, password) {
+  case verify_credentials(username, password, req) {
     Ok(user) -> {
-      let token = session.create_token(user.id)
+      let token = session.create_token(user.id, 3600)
       json.object([#(\"token\", json.string(token))])
     }
     Error(_) -> {
-      let _ = permissions.log_failed_attempt(username)
+      permissions.log_failed_attempt(username, req.client_ip)
       json.object([#(\"error\", json.string(\"unauthorized\"))])
     }
   }
 }"
}

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
  // Attach telemetry listener before starting the agent
  let telemetry = listener.attach()

  let provider =
    openai.provider_with_base_url(api_key(), model(), base_url())

  let cfg =
    pig.new(provider.call)
    |> pig.with_model("code_reviewer")
    |> pig.with_system_prompt(
      "You are a senior code reviewer. You will be given a git diff. "
        <> "Use the list_files and read_file tools to explore the codebase "
        <> "for context before writing your review. "
        <> "\n\n"
        <> "In your review, cover:\n"
        <> "1. **Correctness** — Does the diff do what it intends?\n"
        <> "2. **Side effects** — Does it break existing callers?\n"
        <> "3. **Security** — Any injection, auth, or data exposure risks?\n"
        <> "4. **Style** — Naming, clarity, Gleam idioms.\n"
        <> "\n"
        <> "Be concise. Use bullet points. Flag showstoppers first.",
    )
    |> pig.with_tool(list_files_tool())
    |> pig.with_tool(read_file_tool())

  let assert Ok(agent) = pig.start(cfg)

  io.println("=== Reviewing diff ===")
  io.println("Model: " <> model())
  io.println("Provider: " <> base_url())
  io.println("")

  let result = pig.run_with_timeout(agent, "Review this diff:\n\n" <> diff(), 120_000)

  case result {
    Ok(message.Assistant(content:, ..)) -> {
      io.println("\n=== Review ===\n")
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
      "🧠 Model call (" <> model <> ", " <> int.to_string(message_count)
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

/// Extract a short label from tool arguments for display.
fn format_tool_args(tool_name: String, arguments_json: String) -> String {
  case tool_name {
    "read_file" -> {
      // Try to extract the path from {"path":"..."}
      case json.parse(from: arguments_json, using: decode.field("path", decode.string, decode.success)) {
        Ok(path) -> "(" <> path <> ")"
        Error(_) -> ""
      }
    }
    "list_files" -> ""
    _ -> ""
  }
}
