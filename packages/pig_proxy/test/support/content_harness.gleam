//// Centralized pure content checks; fixture reads are the only IO boundary.

import gleam/list
import gleam/string
import gleeunit/should
import otel/attribute
import pig_otel
import pig_proxy/content
import simplifile

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

@external(erlang, "pig_proxy_content_test_ffi", "scenario")
fn scenario(json: String) -> Scenario

@external(erlang, "pig_proxy_content_test_ffi", "golden")
fn golden(json: String) -> List(#(String, String))

@external(erlang, "pig_proxy_content_test_ffi", "normalize")
fn normalize(value: String) -> String

@external(erlang, "pig_proxy_content_test_ffi", "partitions")
fn partitions(body: BitArray, settings: String) -> List(List(BitArray))

@external(erlang, "pig_proxy_content_test_ffi", "validate")
fn validate(pairs: List(#(String, String)), settings: String) -> Bool

@external(erlang, "pig_proxy_content_test_ffi", "check_validation_cases")
fn check_validation_cases(json: String) -> Bool

/// Exercise typed-shape and semantic guards, not a general JSON Schema engine.
pub fn check_shapes() -> Nil {
  let assert Ok(cases) =
    simplifile.read("test_data/content/validation_cases.json")
  should.be_true(check_validation_cases(cases))
}

fn fixture(name: String) -> #(Scenario, BitArray, String, String) {
  let base = "test_data/content/" <> name
  let assert Ok(settings) = simplifile.read(base <> ".options.json")
  let assert Ok(body) = simplifile.read_bits(base <> ".body")
  let assert Ok(expected) = simplifile.read(base <> ".golden.json")
  #(scenario(settings), body, expected, settings)
}

fn options(scenario: Scenario) -> content.Options {
  let assert Ok(options) =
    content.with_limits(content.defaults(), scenario.source, scenario.budget)
  let assert Ok(options) = content.with_redacted_keys(options, scenario.keys)
  let assert Ok(options) =
    content.with_redacted_text(options, scenario.literals)
  options
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

/// Invalid budgets and rules must fail at configuration time, without echoing data.
pub fn check_options() -> Nil {
  let base = content.defaults()
  should.equal(content.with_limits(base, 0, 1), Error(content.InvalidLimits))
  should.equal(content.with_limits(base, 1, 0), Error(content.InvalidLimits))
  should.equal(
    content.with_limits(base, 1_048_577, 1),
    Error(content.InvalidLimits),
  )
  should.equal(
    content.with_limits(base, 1, 262_145),
    Error(content.InvalidLimits),
  )
  should.equal(
    content.with_redacted_keys(base, [string.repeat("k", 129)]),
    Error(content.InvalidRule),
  )
  should.equal(
    content.with_redacted_text(base, [string.repeat("s", 257)]),
    Error(content.InvalidRule),
  )
  should.equal(
    content.with_redacted_keys(base, [""]),
    Error(content.InvalidRule),
  )
  should.equal(
    content.with_redacted_text(base, [""]),
    Error(content.InvalidRule),
  )
  should.equal(
    content.with_redacted_keys(base, list.repeat("key", 33)),
    Error(content.TooManyRules),
  )
  should.equal(
    content.with_redacted_text(base, list.repeat("secret", 33)),
    Error(content.TooManyRules),
  )
}
