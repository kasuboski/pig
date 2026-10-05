import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import pig_otel
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
  let config.Settings(proxy:, latitude:) = settings
  should.equal(latitude, None)
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
    #("PIG_LATITUDE_ENABLED", "true", "LATITUDE_API_KEY"),
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

pub fn latitude_endpoint_validation_matrix_test() {
  list.each(
    [
      "https://ingest.latitude.so/invalid",
      "http://remote.test/v1/traces",
      "https://user:secret@ingest.latitude.so/v1/traces",
      "https://ingest.latitude.so/v1/traces?key=secret",
    ],
    fn(endpoint) {
      let assert Error(error) =
        check_config(
          list.append(valid(), [
            #("PIG_LATITUDE_ENABLED", "true"),
            #("LATITUDE_API_KEY", "secret"),
            #("LATITUDE_PROJECT", "test-project"),
            #("PIG_LATITUDE_ENDPOINT", endpoint),
          ]),
        )
      should.equal(string.contains(error, "PIG_LATITUDE_ENDPOINT"), True)
      should.equal(string.contains(error, "secret"), False)
    },
  )
}

pub fn capture_and_latitude_are_explicit_test() {
  let env =
    valid()
    |> list.append([
      #("PIG_PROXY_CAPTURE_CONVERSATION", " true "),
      #("PIG_LATITUDE_ENABLED", "true"),
      #("LATITUDE_API_KEY", "private"),
      #("LATITUDE_PROJECT", "project-a"),
    ])
  let assert Ok(config.Settings(proxy:, latitude: Some(latitude))) =
    check_config(env)
  let assert pig_otel.Conversation(_) = proxy.tracing
  should.equal(latitude.endpoint, "https://ingest.latitude.so/v1/traces")
  should.equal(latitude.project, "project-a")
  should.equal(latitude.api_key, "private")
}
