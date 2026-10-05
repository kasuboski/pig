//// Real HTTP/OTLP acceptance against isolated host VMs and loopback providers.

import envoy
import exception
import filepath
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import support/child_vm
import support/otlp_receiver
import support/upstream

const host_eval = "application:set_env(opentelemetry, span_processor, {otel_batch_processor, #{scheduled_delay_ms => 60000}}), subscriptions@host:main()."

type Mode {
  Metadata
  Conversation
  Outage
}

/// Run all acceptance scenarios on synthetic credentials and real loopback IO.
pub fn run() -> Nil {
  let context = child_vm.context()
  let auth =
    filepath.join(
      tmp_dir(),
      "pig-subscriptions-no-auth-" <> child_vm.unique_suffix(),
    )
  let assert Ok(False) = simplifile.is_file(auth)
  list.each([Metadata, Conversation, Outage], fn(mode) {
    run_host(context, auth, mode)
  })
  let probe_environment = [
    #("OPENAI_COMPAT_CODEX_TOKEN", None),
    #("ZAI_API_KEY", None),
    #("LATITUDE_API_KEY", None),
    #("LATITUDE_PROJECT", None),
    #("PIG_LATITUDE_ENABLED", Some("false")),
  ]
  list.each([0, 1, 2, 3, 4, 5, 6], fn(scenario) {
    let eval =
      "support@lifecycle_probe:main(" <> int.to_string(scenario) <> ")."
    let child = child_vm.start(context, eval, probe_environment)
    use <- exception.defer(fn() { child_vm.cleanup(child) })
    let #(status, output) = child_vm.await_exit(child, 5000)
    case scenario {
      0 -> {
        assert status == 0
        assert string.contains(output, "lifecycle shutdown completed")
      }
      _ -> {
        assert status == 1
        assert string.contains(output, "trace delivery is not guaranteed")
      }
    }
    assert !string.contains(output, "private-lifecycle-marker")
  })
  io.println("Subscriptions HTTP, OTLP and shutdown failure acceptance passed.")
}

fn run_host(context: child_vm.Context, auth: String, mode: Mode) -> Nil {
  let codex = upstream.start()
  use <- exception.defer(fn() { upstream.stop(codex) })
  let zai = upstream.start()
  use <- exception.defer(fn() { upstream.stop(zai) })
  let receiver = otlp_receiver.start()
  use <- exception.defer(fn() { otlp_receiver.stop(receiver) })
  let port = child_vm.free_port()
  let env = environment(auth, mode, port, codex, zai, receiver)
  let host = child_vm.start(context, host_eval, env)
  use <- exception.defer(fn() { child_vm.cleanup(host) })
  child_vm.await_ready(host)
  assert request_to(port, http.Get, "/health", "", []).status == 200
  check_models(port)
  list.each(
    [
      #(http.Post, "/v1/models", "{}", 404),
      #(http.Get, "/not-a-route", "", 404),
      #(http.Post, "/v1/unknown", "{}", 404),
      #(http.Post, "/v1/responses", "{}", 400),
      #(http.Post, "/v1/responses", "{\"model\":17}", 400),
      #(http.Post, "/v1/responses", "{\"model\":\"not-configured\"}", 503),
      #(http.Post, "/v1/responses", "{\"model\":\"fake-zai\"}", 503),
      #(http.Post, "/v1/chat/completions", "{\"model\":\"fake-codex\"}", 503),
    ],
    fn(scenario) {
      let #(method, path, body, expected) = scenario
      assert request_to(port, method, path, body, json_headers()).status
        == expected
    },
  )
  assert upstream.count(codex) == 0
  assert upstream.count(zai) == 0
  list.each(
    [
      #(False, "codex-buffered-secret", "00000000000000000000000000000011"),
      #(True, "codex-stream-secret", "00000000000000000000000000000012"),
    ],
    fn(scenario) {
      let #(stream, marker, trace) = scenario
      let body =
        json.object([
          #("model", json.string("fake-codex")),
          #("stream", json.bool(stream)),
          #("store", json.bool(False)),
          #("instructions", json.string("test")),
          #("input", json.string(marker)),
        ])
        |> json.to_string
      let response =
        request_to(
          port,
          http.Post,
          "/v1/responses",
          body,
          traced_headers(trace),
        )
      assert response.status == 200
      assert string.contains(response.body, "responses-output-marker")
      case stream {
        True -> {
          assert string.contains(response.body, "response.completed")
        }
        False -> Nil
      }
      let recorded =
        check_forward(
          codex,
          "/codex/responses",
          "Bearer " <> fake_jwt(),
          "fake-codex",
          stream,
        )
      assert header(recorded, "chatgpt-account-id") == Some("synthetic-account")
      assert header(recorded, "x-api-key") == None
      assert recorded.body == body
      assert string.contains(recorded.body, marker)
      assert !string.contains(recorded.body, "stream_options")
    },
  )
  list.each(
    [
      #(False, "zai-buffered-secret", "00000000000000000000000000000021"),
      #(True, "zai-stream-secret", "00000000000000000000000000000022"),
    ],
    fn(scenario) {
      let #(stream, marker, trace) = scenario
      let body =
        json.object([
          #("model", json.string("fake-zai")),
          #("stream", json.bool(stream)),
          #(
            "messages",
            json.array(
              [
                json.object([
                  #("role", json.string("user")),
                  #("content", json.string(marker)),
                ]),
              ],
              fn(value) { value },
            ),
          ),
        ])
        |> json.to_string
      let response =
        request_to(
          port,
          http.Post,
          "/v1/chat/completions",
          body,
          traced_headers(trace),
        )
      assert response.status == 200
      assert string.contains(response.body, "chat-output-marker")
      let recorded =
        check_forward(
          zai,
          "/v1/chat/completions",
          "Bearer synthetic-zai-key",
          "fake-zai",
          stream,
        )
      list.each(["chatgpt-account-id", "x-api-key", "openai-beta"], fn(key) {
        assert header(recorded, key) == None
      })
      assert string.contains(recorded.body, marker)
      case stream {
        False -> {
          assert recorded.body == body
        }
        True -> {
          let usage_decoder = {
            use include <- decode.field("stream_options", {
              use include <- decode.field("include_usage", decode.bool)
              decode.success(include)
            })
            decode.success(include)
          }
          assert json.parse(recorded.body, usage_decoder) == Ok(True)
        }
      }
    },
  )
  assert upstream.count(codex) == 2
  assert upstream.count(zai) == 2
  otlp_receiver.assert_no_export(receiver)
  child_vm.signal_term(host)
  let #(status, _) = child_vm.await_exit(host, 5000)
  assert status == 0
  let assert Ok(closed_request) = request.to(base_url(port) <> "/health")
  let client = httpc.timeout(httpc.configure(), 250)
  let assert Error(_) = httpc.dispatch(client, closed_request)
  case mode {
    Outage -> Nil
    _ -> otlp_receiver.verify(receiver, mode == Conversation)
  }
  case mode {
    Metadata -> check_startup_rejections(context, env, auth)
    _ -> Nil
  }
}

fn environment(
  auth: String,
  mode: Mode,
  port: Int,
  codex: upstream.Fixture,
  zai: upstream.Fixture,
  receiver: otlp_receiver.Receiver,
) -> List(#(String, Option(String))) {
  let capture = case mode {
    Conversation -> None
    _ -> Some("false")
  }
  let endpoint = case mode {
    Outage -> "http://127.0.0.1:1/v1/traces"
    _ -> otlp_receiver.endpoint(receiver)
  }
  [
    #(
      "PIG_CHATGPT_MODELS",
      Some("fake-codex,gpt-6-astra,gpt-6-sol,gpt-6-luna,gpt-6.1-sol"),
    ),
    #("PIG_ZAI_MODELS", Some("fake-zai,glm-5.3,glm-5.3-flash")),
    #("ZAI_API_KEY", Some("synthetic-zai-key")),
    #("PIG_CHATGPT_BASE_URL", Some(base_url(upstream.port(codex)) <> "/codex")),
    #("PIG_ZAI_BASE_URL", Some(base_url(upstream.port(zai)) <> "/v1")),
    #("PIG_PROXY_PORT", Some(int.to_string(port))),
    #("PIG_PROXY_MODELS_DEV_URL", Some("http://127.0.0.1:1/catalog")),
    #("PIG_CODEX_AUTH_PATH", Some(auth)),
    #("OPENAI_COMPAT_CODEX_TOKEN", Some(fake_jwt())),
    #("PIG_PROXY_CAPTURE_CONVERSATION", capture),
    #("PIG_LATITUDE_ENABLED", Some("true")),
    #("LATITUDE_API_KEY", Some("synthetic-latitude-key")),
    #("LATITUDE_PROJECT", Some("synthetic-project")),
    #("PIG_LATITUDE_ENDPOINT", Some(endpoint)),
    #("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", Some("http://127.0.0.1:1/wrong")),
    #("OTEL_EXPORTER_OTLP_TRACES_HEADERS", Some("Authorization=wrong-key")),
    #("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", Some("grpc")),
    #("OTEL_EXPORTER_OTLP_TRACES_COMPRESSION", Some("gzip")),
    #("OTEL_TRACES_EXPORTER", Some("console")),
    #("OTEL_SDK_DISABLED", Some("true")),
  ]
}

fn check_forward(
  fixture: upstream.Fixture,
  path: String,
  auth: String,
  model: String,
  stream: Bool,
) -> upstream.RecordedRequest {
  let recorded = upstream.take(fixture)
  assert recorded.path == path
  assert header(recorded, "authorization") == Some(auth)
  let model_stream = {
    use model <- decode.field("model", decode.string)
    use stream <- decode.field("stream", decode.bool)
    decode.success(#(model, stream))
  }
  assert json.parse(recorded.body, model_stream) == Ok(#(model, stream))
  let accept = case stream {
    True -> "text/event-stream"
    False -> "application/json"
  }
  assert header(recorded, "accept") == Some(accept)
  case stream, path {
    False, "/v1/chat/completions" -> {
      assert !string.contains(recorded.body, "stream_options")
    }
    _, _ -> Nil
  }
  recorded
}

fn check_models(port: Int) -> Nil {
  let response = request_to(port, http.Get, "/v1/models", "", [])
  assert response.status == 200
  assert response.get_header(response, "content-type") == Ok("application/json")
  let entry_decoder = {
    use id <- decode.field("id", decode.string)
    use owner <- decode.field("owned_by", decode.string)
    use object <- decode.field("object", decode.string)
    use created <- decode.field("created", decode.int)
    decode.success(#(id, owner, object, created))
  }
  let decoder = {
    use object <- decode.field("object", decode.string)
    use entries <- decode.field("data", decode.list(entry_decoder))
    decode.success(#(object, entries))
  }
  let expected =
    [
      #("fake-codex", "openai"),
      #("gpt-6-astra", "openai"),
      #("gpt-6-sol", "openai"),
      #("gpt-6-luna", "openai"),
      #("gpt-6.1-sol", "openai"),
      #("fake-zai", "zai"),
      #("glm-5.3", "zai"),
      #("glm-5.3-flash", "zai"),
    ]
    |> list.map(fn(entry) { #(entry.0, entry.1, "model", 0) })
  assert json.parse(response.body, decoder) == Ok(#("list", expected))
  list.each(
    [
      "synthetic-zai-key",
      fake_jwt(),
      "synthetic-latitude-key",
      "127.0.0.1",
      "base_url",
      "target_id",
    ],
    fn(secret) {
      assert !string.contains(response.body, secret)
    },
  )
  let again = request_to(port, http.Get, "/v1/models", "", json_headers())
  assert again.status == 200
  assert again.body == response.body
}

fn check_startup_rejections(
  context: child_vm.Context,
  env: List(#(String, Option(String))),
  auth: String,
) -> Nil {
  let corrupt = auth <> "-corrupt"
  let assert Ok(Nil) = simplifile.write(corrupt, "{not-json")
  use <- exception.defer(fn() {
    let _ = simplifile.delete(corrupt)
    Nil
  })
  list.each([auth <> "-missing", corrupt], fn(path) {
    let env =
      env
      |> list.key_set("OPENAI_COMPAT_CODEX_TOKEN", None)
      |> list.key_set("PIG_CODEX_AUTH_PATH", Some(path))
    let child = child_vm.start(context, host_eval, env)
    use <- exception.defer(fn() { child_vm.cleanup(child) })
    let #(status, _) = child_vm.await_exit(child, 5000)
    assert status == 2
  })
}

fn request_to(
  port: Int,
  method: http.Method,
  path: String,
  body: String,
  headers: List(#(String, String)),
) -> response.Response(String) {
  let assert Ok(req) = request.to(base_url(port) <> path)
  let req =
    req
    |> request.set_method(method)
    |> request.set_body(body)
    |> request.set_header("connection", "close")
    |> request.set_header("content-type", "application/json")
  let req =
    list.fold(headers, req, fn(req, header) {
      request.set_header(req, header.0, header.1)
    })
  let assert Ok(response) =
    httpc.dispatch(httpc.timeout(httpc.configure(), 5000), req)
  response
}

fn header(recorded: upstream.RecordedRequest, name: String) -> Option(String) {
  case list.key_find(recorded.headers, name) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn json_headers() -> List(#(String, String)) {
  [
    #("authorization", "Bearer synthetic-client-key"),
    #("x-api-key", "synthetic-client-api-key"),
    #("chatgpt-account-id", "synthetic-client-account"),
  ]
}

fn traced_headers(trace: String) -> List(#(String, String)) {
  [#("traceparent", "00-" <> trace <> "-1111111111111111-01"), ..json_headers()]
}

fn fake_jwt() -> String {
  bit_array.base64_url_encode(
    bit_array.from_string("{\"alg\":\"none\"}"),
    False,
  )
  <> "."
  <> bit_array.base64_url_encode(
    bit_array.from_string(
      "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"synthetic-account\"}}",
    ),
    False,
  )
  <> ".synthetic-signature"
}

fn base_url(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}

fn tmp_dir() -> String {
  case envoy.get("TMPDIR") {
    Ok(path) -> path
    Error(_) -> "/tmp"
  }
}
