//// Centralized pure content checks; fixture reads are the only IO boundary.

import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import otel/attribute
import pig_otel
import pig_otel/content
import pig_otel/content/options as content_options
import pig_protocol/message
import pig_protocol/stop_reason

/// Fixture-supplied API, direction, redaction policy and terminal condition.
pub type Scenario {
  Scenario(
    api: pig_otel.Api,
    direction: content.Direction,
    source: Int,
    budget: Int,
    keys: List(String),
    literals: List(String),
    complete: Bool,
  )
}

@external(erlang, "pig_otel_content_test_ffi", "oversized_stream_chunk")
fn oversized_stream_chunk() -> BitArray

@external(erlang, "pig_otel_content_test_ffi", "large_input_body")
fn large_input_body() -> BitArray

@external(erlang, "pig_otel_content_test_ffi", "large_input_body_size")
fn large_input_body_size(size: Int) -> BitArray

@external(erlang, "pig_otel_content_test_ffi", "large_output_body")
fn large_output_body() -> BitArray

@external(erlang, "pig_otel_content_test_ffi", "read_fixture")
fn read_fixture(path: String) -> Result(String, Nil)

@external(erlang, "pig_otel_content_test_ffi", "read_fixture")
fn read_fixture_bits(path: String) -> Result(BitArray, Nil)

@external(erlang, "pig_otel_content_test_ffi", "scenario")
fn scenario(json: String) -> Scenario

@external(erlang, "pig_otel_content_test_ffi", "golden")
fn golden(json: String) -> List(#(String, String))

@external(erlang, "pig_otel_content_test_ffi", "normalize")
fn normalize(value: String) -> String

@external(erlang, "pig_otel_content_test_ffi", "partitions")
fn partitions(body: BitArray, settings: String) -> List(List(BitArray))

@external(erlang, "pig_otel_content_test_ffi", "validate")
fn validate(pairs: List(#(String, String)), settings: String) -> Bool

@external(erlang, "pig_otel_content_test_ffi", "check_validation_cases")
fn check_validation_cases(json: String) -> Bool

/// Exercise typed-shape and semantic guards, not a general JSON Schema engine.
pub fn check_shapes() -> Nil {
  let assert Ok(cases) = read_fixture("test_data/content/validation_cases.json")
  should.be_true(check_validation_cases(cases))
}

fn fixture(name: String) -> #(Scenario, BitArray, String, String) {
  let base = "test_data/content/" <> name
  let assert Ok(settings) = read_fixture(base <> ".options.json")
  let assert Ok(body) = read_fixture_bits(base <> ".body")
  let assert Ok(expected) = read_fixture(base <> ".golden.json")
  #(scenario(settings), body, expected, settings)
}

fn options(scenario: Scenario) -> content_options.Options {
  let assert Ok(config) =
    content_options.with_limits(
      content_options.defaults(),
      scenario.source,
      scenario.budget,
    )
  let assert Ok(config) =
    content_options.with_redacted_keys(config, scenario.keys)
  let assert Ok(config) =
    content_options.with_redacted_text(config, scenario.literals)
  config
}

fn check_attributes(
  capture: content.Capture,
  direction: content.Direction,
  expected: String,
  settings: String,
) -> Nil {
  let pairs =
    list.map(content.attributes(capture, direction), fn(attr) {
      let assert attribute.Attribute(key, attribute.StringValue(value)) = attr
      let assert Ok(pair) =
        list.find(golden(expected), fn(pair) {
          let assert Ok(expected_key) = attribute.key(pair.0)
          expected_key == key
        })
      #(pair.0, value)
    })
  should.be_true(validate(pairs, settings))
  let actual =
    list.map(pairs, fn(pair) {
      let assert Ok(key) = attribute.key(pair.0)
      attribute.string(key, normalize(pair.1))
    })
  let expected =
    list.map(golden(expected), fn(pair) {
      let assert Ok(key) = attribute.key(pair.0)
      attribute.string(key, normalize(pair.1))
    })
  should.equal(list.length(actual), list.length(expected))
  list.each(expected, fn(attr) { should.be_true(list.contains(actual, attr)) })
}

/// Compare the public buffered/input projection against normalized JSON goldens.
pub fn check_content(name: String) -> Nil {
  let #(scenario, body, expected, settings) = fixture(name)
  let capture = case scenario.direction {
    content.Input -> content.input(options(scenario), scenario.api, body)
    content.Output -> content.buffered(options(scenario), scenario.api, body)
  }
  check_attributes(capture, scenario.direction, expected, settings)
}

/// Every fixture is replayed whole and at byte partitions including split UTF-8,
/// CRLF and field names. No sleeps, processes, or transport simulation.
pub fn check_stream(name: String) -> Nil {
  let #(scenario, body, expected, settings) = fixture(name)
  list.each(partitions(body, settings), fn(chunks) {
    let stream =
      list.fold(
        chunks,
        content.new_stream(options(scenario), scenario.api),
        fn(stream, chunk) {
          let next = content.push(stream, chunk)
          should.be_true(content.retained_bytes(next) <= scenario.source)
          next
        },
      )
    case string.contains(expected, "source_limit") {
      True -> should.equal(content.retained_bytes(stream), 0)
      False -> Nil
    }
    check_attributes(
      content.finish(stream, scenario.complete),
      content.Output,
      expected,
      settings,
    )
  })
}

/// Check normalized inputs independently of any provider wire representation.
pub fn check_normalized_projection() -> Nil {
  let assert Ok(expected) =
    read_fixture("test_data/content/normalized_projection.golden")
  let capture =
    content.normalized_input(
      content_options.defaults(),
      Some("system instructions"),
      [message.Developer("keep developer"), message.User("hello")],
      [],
    )
  check_attributes(capture, content.Input, expected, "{}")

  let assert Ok(literal_options) =
    content_options.with_redacted_text(content_options.defaults(), [
      "private phrase",
    ])
  let literal =
    content.normalized_input(
      literal_options,
      None,
      [message.User("private phrase")],
      [],
    )
  check_attributes(
    literal,
    content.Input,
    "{\"pig.content.input.status\":\"filtered\",\"pig.content.input.reason\":\"redacted_or_excluded\",\"gen_ai.input.messages\":[{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"content\":\"[REDACTED]\"}]}]}",
    "{}",
  )

  let nested_tool =
    content.normalized_input(
      content_options.defaults(),
      None,
      [
        message.Assistant(
          "",
          [message.ToolCall("call-1", "lookup", "{\"nested\":{\"value\":1}}")],
          None,
          None,
        ),
      ],
      [],
    )
  check_attributes(
    nested_tool,
    content.Input,
    "{\"pig.content.input.status\":\"captured\",\"pig.content.input.reason\":\"complete\",\"gen_ai.input.messages\":[{\"role\":\"assistant\",\"parts\":[{\"type\":\"tool_call\",\"id\":\"call-1\",\"name\":\"lookup\",\"arguments\":{\"nested\":{\"value\":1}}}]}]}",
    "{}",
  )

  let assert Ok(output_expected) =
    read_fixture("test_data/content/normalized_output.golden")
  let output =
    content.normalized_output(
      content_options.defaults(),
      message.Assistant("answer", [], None, None),
      Some(stop_reason.Stop),
    )
  check_attributes(output, content.Output, output_expected, "{}")

  let assert Ok(limited_options) =
    content_options.with_limits(content_options.defaults(), 4, 16_384)
  let limited =
    content.normalized_output(
      limited_options,
      message.Assistant("oversized", [], None, None),
      Some(stop_reason.Stop),
    )
  check_attributes(
    limited,
    content.Output,
    "{\"pig.content.output.status\":\"omitted\",\"pig.content.output.reason\":\"source_limit\"}",
    "{}",
  )

  let ambiguous =
    content.normalized_output(
      content_options.defaults(),
      message.Assistant("provider error", [], None, None),
      Some(stop_reason.Error),
    )
  check_attributes(
    ambiguous,
    content.Output,
    "{\"pig.content.output.status\":\"omitted\",\"pig.content.output.reason\":\"incomplete\"}",
    "{}",
  )

  let unknown =
    content.normalized_output(
      content_options.defaults(),
      message.Assistant("provider error", [], None, None),
      Some(stop_reason.Unknown("failed")),
    )
  check_attributes(
    unknown,
    content.Output,
    "{\"pig.content.output.status\":\"omitted\",\"pig.content.output.reason\":\"incomplete\"}",
    "{}",
  )
}

fn input_messages(capture: content.Capture) -> String {
  let assert Ok(messages_key) = attribute.key("gen_ai.input.messages")
  let assert Ok(messages) =
    list.find(content.attributes(capture, content.Input), fn(attr) {
      let attribute.Attribute(key, _) = attr
      key == messages_key
    })
  let assert attribute.Attribute(_, attribute.StringValue(value)) = messages
  value
}

fn input_messages_bytes(capture: content.Capture) -> Int {
  bit_array.byte_size(bit_array.from_string(input_messages(capture)))
}

fn check_status(
  capture: content.Capture,
  direction: content.Direction,
  expected: String,
) -> Nil {
  let assert Ok(status_key) =
    attribute.key(case direction {
      content.Input -> "pig.content.input.status"
      content.Output -> "pig.content.output.status"
    })
  let assert Ok(status) =
    list.find(content.attributes(capture, direction), fn(attr) {
      let attribute.Attribute(key, _) = attr
      key == status_key
    })
  let assert attribute.Attribute(_, attribute.StringValue(value)) = status
  should.equal(value, expected)
}

/// Exercise budgets above the historical defaults and verify they remain directional.
pub fn check_directional_budgets() -> Nil {
  let long_text = string.repeat("x", 70_000)
  let default_options = content_options.defaults()
  let large_body_capture =
    content.input(default_options, pig_otel.ChatCompletions, large_input_body())
  check_status(large_body_capture, content.Input, "captured")
  should.be_true(input_messages_bytes(large_body_capture) > 262_144)

  let large_normalized_capture =
    content.normalized_input(
      default_options,
      None,
      [message.User(string.repeat("n", 1_200_000) <> "large-input-end")],
      [],
    )
  check_status(large_normalized_capture, content.Input, "captured")
  should.be_true(input_messages_bytes(large_normalized_capture) > 262_144)
  should.be_true(string.contains(
    input_messages(large_normalized_capture),
    "large-input-end",
  ))

  let one_character_projection =
    content.normalized_input(default_options, None, [message.User("c")], [])
  let exact_content_text_bytes =
    2_097_152 - input_messages_bytes(one_character_projection) + 1
  let exact_content_capture =
    content.normalized_input(
      default_options,
      None,
      [message.User(string.repeat("c", exact_content_text_bytes))],
      [],
    )
  check_status(exact_content_capture, content.Input, "captured")
  should.equal(input_messages_bytes(exact_content_capture), 2_097_152)
  let content_overflow_capture =
    content.normalized_input(
      default_options,
      None,
      [message.User(string.repeat("c", exact_content_text_bytes + 1))],
      [],
    )
  check_attributes(
    content_overflow_capture,
    content.Input,
    "{\"pig.content.input.status\":\"omitted\",\"pig.content.input.reason\":\"content_limit\"}",
    "{}",
  )

  let normalized_source_overflow =
    content.normalized_input(
      default_options,
      None,
      [message.User(string.repeat("s", 4_194_305))],
      [],
    )
  check_attributes(
    normalized_source_overflow,
    content.Input,
    "{\"pig.content.input.status\":\"omitted\",\"pig.content.input.reason\":\"source_limit\"}",
    "{}",
  )

  let source_at_limit =
    content.input(
      default_options,
      pig_otel.ChatCompletions,
      large_input_body_size(4_194_304),
    )
  check_attributes(
    source_at_limit,
    content.Input,
    "{\"pig.content.input.status\":\"omitted\",\"pig.content.input.reason\":\"content_limit\"}",
    "{}",
  )

  let source_overflow =
    content.input(
      default_options,
      pig_otel.ChatCompletions,
      large_input_body_size(4_194_305),
    )
  check_attributes(
    source_overflow,
    content.Input,
    "{\"pig.content.input.status\":\"omitted\",\"pig.content.input.reason\":\"source_limit\"}",
    "{}",
  )
  check_status(
    content.normalized_input(
      default_options,
      None,
      [message.User(long_text)],
      [],
    ),
    content.Input,
    "captured",
  )
  check_status(
    content.normalized_output(
      default_options,
      message.Assistant(long_text, [], None, None),
      Some(stop_reason.Stop),
    ),
    content.Output,
    "omitted",
  )

  let assert Ok(output_options) =
    content_options.with_direction_limits(
      default_options,
      content_options.OutputLimits(100_000, 100_000),
    )
  check_status(
    content.normalized_output(
      output_options,
      message.Assistant(long_text, [], None, None),
      Some(stop_reason.Stop),
    ),
    content.Output,
    "captured",
  )
  check_status(
    content.buffered(
      output_options,
      pig_otel.ChatCompletions,
      large_output_body(),
    ),
    content.Output,
    "captured",
  )
  check_status(
    content.normalized_input(
      output_options,
      None,
      [message.User(long_text)],
      [],
    ),
    content.Input,
    "captured",
  )

  let source_options =
    content_options.with_direction_limits(
      default_options,
      content_options.InputLimits(100_000, 100_000),
    )
  let assert Ok(source_options) = source_options
  let source_only = string.repeat("z", 70_000)
  check_status(
    content.normalized_input(
      source_options,
      None,
      [message.User(source_only)],
      [],
    ),
    content.Input,
    "captured",
  )

  let assert Ok(stream_options) =
    content_options.with_direction_limits(
      default_options,
      content_options.OutputLimits(1024, 65_536),
    )
  let stream = content.new_stream(stream_options, pig_otel.ChatCompletions)
  let first_chunk = content.push(stream, oversized_stream_chunk())
  should.equal(content.retained_bytes(first_chunk), 600)
  let failed = content.push(first_chunk, oversized_stream_chunk())
  should.equal(content.retained_bytes(failed), 0)
  check_status(content.finish(failed, True), content.Output, "omitted")
  Nil
}

/// Invalid budgets and rules must fail at configuration time, without echoing data.
pub fn check_options() -> Nil {
  let base = content_options.defaults()
  should.equal(
    content_options.with_limits(base, 0, 1),
    Error(content_options.InvalidLimits),
  )
  should.equal(
    content_options.with_limits(base, 1, 0),
    Error(content_options.InvalidLimits),
  )
  should.equal(
    content_options.with_limits(base, 4_194_305, 1),
    Error(content_options.InvalidLimits),
  )
  should.equal(
    content_options.with_limits(base, 1, 2_097_153),
    Error(content_options.InvalidLimits),
  )
  let assert Ok(_at_caps) =
    content_options.with_limits(base, 4_194_304, 2_097_152)
  should.equal(
    content_options.with_direction_limits(
      base,
      content_options.InputLimits(4_194_305, 1),
    ),
    Error(content_options.InvalidLimits),
  )
  should.equal(
    content_options.with_direction_limits(
      base,
      content_options.OutputLimits(1, 2_097_153),
    ),
    Error(content_options.InvalidLimits),
  )
  let assert Ok(_output_caps) =
    content_options.with_direction_limits(
      base,
      content_options.OutputLimits(4_194_304, 2_097_152),
    )
  should.equal(
    content_options.with_redacted_keys(base, [string.repeat("k", 129)]),
    Error(content_options.InvalidRule),
  )
  should.equal(
    content_options.with_redacted_text(base, [string.repeat("s", 257)]),
    Error(content_options.InvalidRule),
  )
  should.equal(
    content_options.with_redacted_keys(base, [""]),
    Error(content_options.InvalidRule),
  )
  should.equal(
    content_options.with_redacted_text(base, [""]),
    Error(content_options.InvalidRule),
  )
  should.equal(
    content_options.with_redacted_keys(base, list.repeat("key", 33)),
    Error(content_options.TooManyRules),
  )
  should.equal(
    content_options.with_redacted_text(base, list.repeat("secret", 33)),
    Error(content_options.TooManyRules),
  )
}
