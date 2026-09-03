import gleam/float
import gleam/option.{None, Some}
import gleeunit
import pig_proxy/model_catalog

pub fn main() -> Nil {
  gleeunit.main()
}

const sample_json = "{
  \"openai\": {
    \"id\": \"openai\",
    \"models\": {
      \"openai/gpt-4o\": {
        \"id\": \"openai/gpt-4o\",
        \"cost\": { \"input\": 5, \"output\": 15, \"cache_read\": 2.5 },
        \"limit\": { \"context\": 128000, \"output\": 16384 },
        \"tool_call\": true,
        \"structured_output\": true
      },
      \"openai/gpt-4o-mini\": {
        \"id\": \"openai/gpt-4o-mini\",
        \"cost\": { \"input\": 0.15, \"output\": 0.6 },
        \"limit\": { \"context\": 128000, \"output\": 16384 },
        \"tool_call\": true,
        \"structured_output\": true
      }
    }
  },
  \"anthropic\": {
    \"id\": \"anthropic\",
    \"models\": {
      \"anthropic/claude-3-5-sonnet\": {
        \"id\": \"anthropic/claude-3-5-sonnet\",
        \"cost\": { \"input\": 3, \"output\": 15, \"cache_read\": 0.3, \"cache_write\": 3.75 },
        \"limit\": { \"context\": 200000, \"output\": 8192 },
        \"tool_call\": true,
        \"structured_output\": false
      }
    }
  }
}"

// ── parse ───────────────────────────────────────────────────────

pub fn parse_flattens_provider_models_test() {
  let assert Ok(catalog) = model_catalog.parse(sample_json)
  let assert Some(gpt4o) = model_catalog.find(catalog, "openai/gpt-4o")
  assert gpt4o.input_price == Some(5.0)
  assert gpt4o.output_price == Some(15.0)
  assert gpt4o.cache_read_price == Some(2.5)
  assert gpt4o.context_limit == Some(128_000)
  assert gpt4o.output_limit == Some(16_384)
  assert gpt4o.tool_call == True
  assert gpt4o.structured_output == True
}

pub fn parse_handles_integer_and_float_prices_test() {
  let assert Ok(catalog) = model_catalog.parse(sample_json)
  let assert Some(gpt4o) = model_catalog.find(catalog, "openai/gpt-4o")
  let assert Some(mini) = model_catalog.find(catalog, "openai/gpt-4o-mini")
  assert gpt4o.input_price == Some(5.0)
  assert mini.input_price == Some(0.15)
}

pub fn parse_missing_model_returns_none_test() {
  let assert Ok(catalog) = model_catalog.parse(sample_json)
  assert model_catalog.find(catalog, "openai/nonexistent") == None
}

pub fn parse_indexes_bare_model_name_test() {
  let assert Ok(catalog) = model_catalog.parse(sample_json)
  // Bare name (no provider prefix) should also resolve
  let assert Some(gpt4o) = model_catalog.find(catalog, "gpt-4o")
  assert gpt4o.input_price == Some(5.0)
  let assert Some(sonnet) = model_catalog.find(catalog, "claude-3-5-sonnet")
  assert sonnet.input_price == Some(3.0)
}

pub fn parse_ignores_extra_fields_test() {
  let json =
    "{
    \"provider\": {
      \"id\": \"provider\",
      \"models\": {
        \"p/m\": {
          \"id\": \"p/m\",
          \"cost\": { \"input\": 1 },
          \"extra\": \"ignored\"
        }
      }
    }
  }"
  let assert Ok(catalog) = model_catalog.parse(json)
  let assert Some(model) = model_catalog.find(catalog, "p/m")
  assert model.input_price == Some(1.0)
  assert model.output_price == None
}

// ── cost_usd ────────────────────────────────────────────────────

pub fn cost_usd_computes_from_prices_test() {
  let info =
    model_catalog.ModelInfo(
      input_price: Some(5.0),
      output_price: Some(15.0),
      cache_read_price: None,
      cache_write_price: None,
      context_limit: None,
      output_limit: None,
      tool_call: True,
      structured_output: True,
    )
  let cost = model_catalog.cost_usd(info, 1000, 500, 0)
  // (1000 * 5 / 1e6) + (500 * 15 / 1e6) = 0.005 + 0.0075 = 0.0125
  assert float.loosely_equals(cost, 0.0125, 0.000_001)
}

pub fn cost_usd_bills_cached_tokens_at_cache_read_price_test() {
  let info =
    model_catalog.ModelInfo(
      input_price: Some(5.0),
      output_price: Some(15.0),
      cache_read_price: Some(0.5),
      cache_write_price: None,
      context_limit: None,
      output_limit: None,
      tool_call: True,
      structured_output: True,
    )
  // OpenAI counts cached tokens inside the input total: 400 of the 1000
  // input tokens were cache hits, so they bill at the cache-read price.
  // (600 * 5 + 400 * 0.5 + 500 * 15) / 1e6 = 0.0107
  let cost = model_catalog.cost_usd(info, 1000, 500, 400)
  assert float.loosely_equals(cost, 0.0107, 0.000_001)
}

pub fn cost_usd_without_cache_price_falls_back_to_input_price_test() {
  let info =
    model_catalog.ModelInfo(
      input_price: Some(5.0),
      output_price: None,
      cache_read_price: None,
      cache_write_price: None,
      context_limit: None,
      output_limit: None,
      tool_call: True,
      structured_output: True,
    )
  // No catalogued cache price: cached tokens bill at the input price, so
  // the split between cached and uncached makes no difference.
  let cost = model_catalog.cost_usd(info, 1000, 0, 400)
  assert float.loosely_equals(cost, 0.005, 0.000_001)
}

pub fn cost_usd_clamps_cached_above_input_test() {
  let info =
    model_catalog.ModelInfo(
      input_price: Some(5.0),
      output_price: None,
      cache_read_price: Some(0.5),
      cache_write_price: None,
      context_limit: None,
      output_limit: None,
      tool_call: True,
      structured_output: True,
    )
  // A malformed cached count above the input total must not go negative
  // on the uncached portion — it is clamped to the input total.
  let cost = model_catalog.cost_usd(info, 100, 0, 500)
  assert float.loosely_equals(cost, 0.00005, 0.000_001)
}

pub fn cost_usd_missing_prices_are_zero_test() {
  let info =
    model_catalog.ModelInfo(
      input_price: None,
      output_price: None,
      cache_read_price: None,
      cache_write_price: None,
      context_limit: None,
      output_limit: None,
      tool_call: False,
      structured_output: False,
    )
  assert model_catalog.cost_usd(info, 1000, 500, 0) == 0.0
}

pub fn empty_catalog_has_no_models_test() {
  let catalog = model_catalog.empty()
  assert model_catalog.find(catalog, "anything") == None
}
