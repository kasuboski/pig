import gleam/bit_array
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import pig_otel
import pig_otel/content
import pig_proxy/config as proxy_config
import subscriptions/config

fn lookup(
  values: List(#(String, String)),
) -> fn(String) -> option.Option(String) {
  fn(key) {
    case dict.get(dict.from_list(values), key) {
      Ok(value) -> Some(value)
      Error(_) -> None
    }
  }
}

fn check_config(
  values: List(#(String, String)),
) -> Result(config.Settings, String) {
  config.parse(lookup(values))
}

fn valid() -> List(#(String, String)) {
  [
    #("PIG_CHATGPT_MODELS", " gpt-5-codex, o4-mini "),
    #("PIG_ZAI_MODELS", " GLM-5 "),
    #("ZAI_API_KEY", " secret "),
  ]
}

pub fn defaults_and_exact_routes_test() {
  let assert Ok(settings) = check_config(valid())
  let config.Settings(proxy:, otlp:) = settings
  should.equal(otlp, None)
  should.equal(proxy.bind, "127.0.0.1")
  should.equal(proxy.port, 8080)
  let assert pig_otel.Conversation(_) = proxy.tracing
}

pub fn explicit_bind_address_test() {
  list.each(["127.0.0.1", "0.0.0.0"], fn(bind) {
    let assert Ok(settings) =
      check_config(
        list.append(valid(), [#("PIG_PROXY_BIND", " " <> bind <> " ")]),
      )
    should.equal(settings.proxy.bind, bind)
  })
}

pub fn explicit_metadata_only_override_test() {
  let assert Ok(settings) =
    check_config(
      list.append(valid(), [
        #("PIG_PROXY_CAPTURE_CONVERSATION", "false"),
      ]),
    )
  let assert pig_otel.MetadataOnly = settings.proxy.tracing
}

pub fn required_variables_and_trimmed_models_test() {
  let assert Ok(settings) = check_config(valid())
  let config.Settings(proxy:, ..) = settings
  let assert proxy_config.StrictRoutes(routes) = proxy.routing
  should.equal(
    list.map(routes, fn(route) {
      let proxy_config.ModelRoute(model:, ..) = route
      model
    }),
    ["gpt-5-codex", "o4-mini", "GLM-5"],
  )
  should.equal(
    list.map(routes, fn(route) {
      let proxy_config.ModelRoute(target_id:, ..) = route
      target_id
    }),
    ["chatgpt", "chatgpt", "zai"],
  )
}

pub fn required_inputs_missing_test() {
  list.each(["PIG_CHATGPT_MODELS", "PIG_ZAI_MODELS", "ZAI_API_KEY"], fn(key) {
    let env =
      list.filter(valid(), fn(entry) {
        let #(name, _) = entry
        name != key
      })
    let assert Error(error) = check_config(env)
    should.equal(string.contains(error, key), True)
  })
}

pub fn parser_rejects_matrix_test() {
  let cases = [
    #("PIG_CHATGPT_MODELS", "", "PIG_CHATGPT_MODELS"),
    #("PIG_CHATGPT_MODELS", "a,,b", "PIG_CHATGPT_MODELS"),
    #("PIG_CHATGPT_MODELS", "a, a", "PIG_CHATGPT_MODELS"),
    #("PIG_ZAI_MODELS", "a, ", "PIG_ZAI_MODELS"),
    #("ZAI_API_KEY", "  ", "ZAI_API_KEY"),
    #("PIG_PROXY_PORT", "65536", "PIG_PROXY_PORT"),
    #("PIG_PROXY_PORT", "0", "PIG_PROXY_PORT"),
    #("PIG_PROXY_PORT", "not-a-port", "PIG_PROXY_PORT"),
    #("PIG_PROXY_BIND", "", "PIG_PROXY_BIND"),
    #("PIG_PROXY_BIND", "remote.test", "PIG_PROXY_BIND"),
    #("PIG_PROXY_BIND", "127.0.0.1\nsecret", "PIG_PROXY_BIND"),
    #("PIG_PROXY_CAPTURE_CONVERSATION", "yes", "PIG_PROXY_CAPTURE_CONVERSATION"),
    #(
      "PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES",
      "0",
      "PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES",
      "4194305",
      "PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES",
      "four",
      "PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES",
      "0",
      "PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES",
      "2097153",
      "PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES",
      "large",
      "PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES",
      "0",
      "PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES",
      "4194305",
      "PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES",
      "bad",
      "PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES",
      "0",
      "PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES",
      "2097153",
      "PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES",
    ),
    #(
      "PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES",
      "not-an-integer",
      "PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES",
    ),
    #("ZAI_API_KEY", "secret\r\ninjected: value", "ZAI_API_KEY"),
    #("PIG_CHATGPT_BASE_URL", "", "PIG_CHATGPT_BASE_URL"),
    #("PIG_ZAI_BASE_URL", "http://remote.test/v1", "PIG_ZAI_BASE_URL"),
    #(
      "PIG_ZAI_BASE_URL",
      "https://user:secret@remote.test/v1",
      "PIG_ZAI_BASE_URL",
    ),
    #(
      "PIG_ZAI_BASE_URL",
      "https://remote.test/v1?token=secret",
      "PIG_ZAI_BASE_URL",
    ),
    #(
      "PIG_PROXY_MODELS_DEV_URL",
      "file:///tmp/catalog",
      "PIG_PROXY_MODELS_DEV_URL",
    ),
    #(
      "OTEL_EXPORTER_OTLP_ENDPOINT",
      "http://localhost:4318/v1/traces\r\ninjected: value",
      "OTEL_EXPORTER_OTLP_ENDPOINT",
    ),
    #(
      "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
      "http://localhost:4318/v1/traces\ninjected: value",
      "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    ),
  ]
  list.each(cases, fn(test_case) {
    let #(key, value, expected) = test_case
    let env = valid() |> list.append([#(key, value)])
    let assert Error(error) = check_config(env)
    should.equal(string.contains(error, expected), True)
    should.equal(string.contains(error, "secret"), False)
  })
}

pub fn base_overrides_are_exact_test() {
  let env =
    valid()
    |> list.append([
      #("PIG_CHATGPT_BASE_URL", "http://127.0.0.1:9001"),
      #("PIG_ZAI_BASE_URL", "http://127.0.0.1:9002"),
      #("PIG_PROXY_PORT", "19080"),
    ])
  let assert Ok(config.Settings(proxy:, ..)) = check_config(env)
  should.equal(proxy.port, 19_080)
  let assert [chatgpt, zai] = proxy.targets
  should.equal(chatgpt.base_url, "http://127.0.0.1:9001")
  should.equal(zai.base_url, "http://127.0.0.1:9002")
  should.equal(proxy_config.provider_string(chatgpt), "openai")
  should.equal(proxy_config.provider_string(zai), "zai")
}

pub fn otlp_endpoint_and_protocol_validation_test() {
  list.each(
    [
      #("OTEL_EXPORTER_OTLP_ENDPOINT", "https://user:secret@collector.example"),
      #("OTEL_EXPORTER_OTLP_ENDPOINT", " https://collector.example "),
      #(
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
        " https://collector.example/path ",
      ),
      #(
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
        "https://collector.example/path?secret",
      ),
    ],
    fn(test_case) {
      let #(key, value) = test_case
      let assert Error(error) =
        check_config(valid() |> list.append([#(key, value)]))
      should.equal(string.contains(error, key), True)
      should.equal(string.contains(error, "secret"), False)
    },
  )
  let assert Error(protocol_error) =
    check_config(
      valid()
      |> list.append([
        #("OTEL_EXPORTER_OTLP_ENDPOINT", "https://collector.example"),
        #("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc"),
      ]),
    )
  should.equal(string.contains(protocol_error, "PROTOCOL"), True)
  list.each(["HTTP/PROTOBUF", " http/protobuf "], fn(value) {
    let assert Error(error) =
      check_config(
        valid()
        |> list.append([
          #("OTEL_EXPORTER_OTLP_ENDPOINT", "https://collector.example"),
          #("OTEL_EXPORTER_OTLP_PROTOCOL", value),
        ]),
      )
    should.equal(string.contains(error, "PROTOCOL"), True)
  })
}

pub fn standard_otlp_endpoint_selection_test() {
  let assert Ok(config.Settings(otlp: Some(otlp), ..)) =
    check_config(
      valid()
      |> list.append([
        #("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector.example:4318/base"),
        #(
          "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
          "https://collector.example/custom/traces",
        ),
        #("OTEL_EXPORTER_OTLP_PROTOCOL", "unsupported-is-overridden"),
        #("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "http/protobuf"),
      ]),
    )
  should.equal(otlp.endpoint, Some("http://collector.example:4318/base"))
  should.equal(
    otlp.traces_endpoint,
    Some("https://collector.example/custom/traces"),
  )
  should.equal(otlp.protocol, config.HttpProtobuf)
}

pub fn traces_exporter_values_match_sdk_raw_environment_test() {
  let assert Ok(config.Settings(otlp: Some(_), ..)) =
    check_config(valid() |> list.append([#("OTEL_TRACES_EXPORTER", "otlp")]))
  let assert Ok(config.Settings(otlp: None, ..)) =
    check_config(valid() |> list.append([#("OTEL_TRACES_EXPORTER", "none")]))
  list.each(["OTLP", " otlp ", "jaeger", ""], fn(value) {
    let assert Error(error) =
      check_config(valid() |> list.append([#("OTEL_TRACES_EXPORTER", value)]))
    should.equal(string.contains(error, "OTEL_TRACES_EXPORTER"), True)
  })
}

pub fn traces_exporter_none_overrides_endpoints_test() {
  list.each(
    [
      [#("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector.example:4318")],
      [
        #(
          "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
          "https://collector.example/v1/traces",
        ),
      ],
      [
        #("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector.example:4318"),
        #(
          "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
          "https://collector.example/v1/traces",
        ),
      ],
    ],
    fn(endpoints) {
      let assert Ok(config.Settings(otlp: None, ..)) =
        check_config(
          valid()
          |> list.append(endpoints)
          |> list.append([#("OTEL_TRACES_EXPORTER", "none")]),
        )
    },
  )
}

pub fn otlp_requires_endpoint_test() {
  let assert Error(protocol_error) =
    check_config(
      valid()
      |> list.append([
        #("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc"),
      ]),
    )
  should.equal(string.contains(protocol_error, "PROTOCOL"), True)
  let assert Ok(config.Settings(otlp: Some(_), ..)) =
    check_config(
      valid()
      |> list.append([
        #(
          "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
          "https://collector.example/v1/traces",
        ),
      ]),
    )
}

pub fn directional_capture_budgets_accept_valid_overrides_test() {
  let env =
    valid()
    |> list.append([
      #("PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES", "123456"),
      #("PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES", "100"),
      #("PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES", "345678"),
      #("PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES", "4096"),
    ])
  let assert Ok(config.Settings(proxy:, ..)) = check_config(env)
  let assert pig_otel.Conversation(capture_options) = proxy.tracing
  let input =
    content.input(
      capture_options,
      pig_otel.ChatCompletions,
      bit_array.from_string(
        "{\"messages\":[{\"role\":\"user\",\"content\":\""
        <> string.repeat("x", 500)
        <> "\"}]}",
      ),
    )
  let output =
    content.buffered(
      capture_options,
      pig_otel.ChatCompletions,
      bit_array.from_string(
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\""
        <> string.repeat("y", 500)
        <> "\"},\"finish_reason\":\"stop\"}]}",
      ),
    )
  should.equal(list.length(content.attributes(input, content.Input)), 2)
  should.equal(list.length(content.attributes(output, content.Output)), 3)
}

pub fn invalid_capture_budgets_rejected_when_capture_disabled_test() {
  let assert Error(error) =
    check_config(
      valid()
      |> list.append([
        #("PIG_PROXY_CAPTURE_CONVERSATION", "false"),
        #("PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES", "0"),
      ]),
    )
  should.equal(
    string.contains(error, "PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES"),
    True,
  )
}

pub fn capture_and_otlp_are_explicit_test() {
  let env =
    valid()
    |> list.append([
      #("PIG_PROXY_CAPTURE_CONVERSATION", " true "),
      #(
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
        "https://collector.example/v1/traces",
      ),
    ])
  let assert Ok(config.Settings(proxy:, otlp: Some(_))) = check_config(env)
  let assert pig_otel.Conversation(_) = proxy.tracing
}
