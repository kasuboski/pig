import gleam/float
import gleam/option.{None, Some}
import pig_proxy/model_catalog.{
  Complete, InputOnly, OutputOnly, Unknown, UnknownTier,
}
import support/pricing_harness

pub fn models_dev_bare_model_key_is_qualified_by_provider_test() {
  let assert Complete(input, output, _) =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openai",
      "gpt-6-astra",
      Some(1000),
      Some(1000),
      None,
    )
  assert float.loosely_equals(input, 0.01, 0.000_000_001)
  assert float.loosely_equals(output, 0.05, 0.000_000_001)
}

pub fn models_dev_context_tier_uses_strict_context_size_boundary_test() {
  let assert Complete(base_input, base_output, _) =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openai",
      "gpt-6-astra",
      Some(272_000),
      Some(1000),
      None,
    )
  assert float.loosely_equals(base_input, 2.72, 0.000_000_001)
  assert float.loosely_equals(base_output, 0.05, 0.000_000_001)

  let assert Complete(tier_input, tier_output, _) =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openai",
      "gpt-6-astra",
      Some(272_001),
      Some(1000),
      None,
    )
  assert float.loosely_equals(tier_input, 5.44002, 0.000_000_001)
  assert float.loosely_equals(tier_output, 0.075, 0.000_000_001)
}

pub fn context_tier_without_cache_price_falls_back_to_input_rate_test() {
  let assert Complete(input, output, _) =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openai",
      "optional-cache-tier",
      Some(11),
      Some(1),
      Some(10),
    )
  assert float.loosely_equals(input, 0.00022, 0.000_000_001)
  assert float.loosely_equals(output, 0.000075, 0.000_000_001)
}

pub fn unsupported_tier_is_unknown_priced_without_poisoning_catalog_test() {
  let assert UnknownTier =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openai",
      "future-tier-model",
      Some(1000),
      Some(1000),
      None,
    )
  let assert Complete(_, _, _) =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openai",
      "gpt-6-astra",
      Some(1000),
      Some(1000),
      None,
    )
}

pub fn provider_collision_does_not_fall_through_to_bare_alias_test() {
  let assert Complete(openai_input, _, _) =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openai",
      "gpt-6-astra",
      Some(1000),
      Some(0),
      None,
    )
  let assert Complete(openrouter_input, _, _) =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openrouter",
      "gpt-6-astra",
      Some(1000),
      Some(0),
      None,
    )
  let assert Unknown =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "missing-provider",
      "gpt-6-astra",
      Some(1000),
      Some(1000),
      None,
    )
  assert float.loosely_equals(openai_input, 0.01, 0.000_000_001)
  assert float.loosely_equals(openrouter_input, 0.099, 0.000_000_001)
}

pub fn openrouter_vendor_key_is_qualified_by_outer_provider_test() {
  let assert Complete(input, output, _) =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openrouter",
      "openai/model-x",
      Some(1000),
      Some(1000),
      None,
    )
  assert float.loosely_equals(input, 0.003, 0.000_000_001)
  assert float.loosely_equals(output, 0.007, 0.000_000_001)
}

pub fn openrouter_foreign_vendor_collision_does_not_overwrite_openai_test() {
  let assert Complete(openai_input, _, _) =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openai",
      "gpt-6-astra",
      Some(1000),
      Some(0),
      None,
    )
  let assert Complete(openrouter_input, _, _) =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openrouter",
      "openai/gpt-6-astra",
      Some(1000),
      Some(0),
      None,
    )
  assert float.loosely_equals(openai_input, 0.01, 0.000_000_001)
  assert float.loosely_equals(openrouter_input, 0.099, 0.000_000_001)
}

pub fn context_tier_missing_size_is_unknown_tier_test() {
  let assert UnknownTier =
    pricing_harness.check_estimate_from(
      "test_data/models_dev_pricing_regression.json",
      "openai",
      "missing-tier-size",
      Some(1000),
      Some(1000),
      None,
    )
}

pub fn exact_provider_model_prices_are_used_test() {
  let estimate =
    pricing_harness.check_estimate(
      "provider-a",
      "shared",
      Some(1000),
      Some(500),
      Some(400),
    )
  let assert Complete(input, output, total) = estimate
  assert float.loosely_equals(input, 0.0028, 0.000_000_001)
  assert float.loosely_equals(output, 0.006, 0.000_000_001)
  assert float.loosely_equals(total, 0.0088, 0.000_000_001)
  let assert Unknown =
    pricing_harness.check_estimate(
      "provider-c",
      "shared",
      Some(1000),
      Some(500),
      None,
    )
  let assert OutputOnly(output) =
    pricing_harness.check_estimate("provider-b", "shared", None, Some(0), None)
  assert output == 0.0
  let assert Unknown =
    pricing_harness.check_estimate(
      "provider-a",
      "shared",
      Some(-1),
      Some(500),
      None,
    )
  let assert Complete(input, output, _) =
    pricing_harness.check_estimate(
      "provider-b",
      "tiered",
      Some(101),
      Some(1000),
      Some(1),
    )
  assert float.loosely_equals(input, 0.000_802, 0.000_000_001)
  assert float.loosely_equals(output, 0.02, 0.000_000_001)
}

pub fn tiers_select_highest_threshold_with_strict_boundary_test() {
  let assert Complete(base_input, base_output, _) =
    pricing_harness.check_estimate(
      "provider-b",
      "tiered",
      Some(100),
      Some(1000),
      None,
    )
  assert float.loosely_equals(base_input, 0.0001, 0.000_000_001)
  assert float.loosely_equals(base_output, 0.005, 0.000_000_001)
  let assert Complete(high_input, high_output, _) =
    pricing_harness.check_estimate(
      "provider-b",
      "tiered",
      Some(1001),
      Some(1000),
      Some(1001),
    )
  assert float.loosely_equals(high_input, 0.003003, 0.000_000_001)
  assert float.loosely_equals(high_output, 0.03, 0.000_000_001)
  let assert UnknownTier =
    pricing_harness.check_estimate(
      "provider-b",
      "tiered",
      None,
      Some(100),
      None,
    )
}

pub fn cached_count_absence_assumes_zero_and_cached_subset_is_clamped_test() {
  let assert InputOnly(no_cache_usage) =
    pricing_harness.check_estimate(
      "provider-b",
      "shared",
      Some(1000),
      None,
      None,
    )
  assert float.loosely_equals(no_cache_usage, 0.02, 0.000_000_001)
  let assert InputOnly(all_cached) =
    pricing_harness.check_estimate(
      "provider-a",
      "shared",
      Some(1000),
      None,
      Some(1000),
    )
  assert float.loosely_equals(all_cached, 0.001, 0.000_000_001)
  let assert InputOnly(clamped) =
    pricing_harness.check_estimate(
      "provider-a",
      "shared",
      Some(1000),
      None,
      Some(2000),
    )
  assert float.loosely_equals(clamped, 0.001, 0.000_000_001)
  let assert InputOnly(cache_only) =
    pricing_harness.check_estimate(
      "provider-b",
      "cache-only",
      Some(1000),
      None,
      Some(1000),
    )
  assert float.loosely_equals(cache_only, 0.0005, 0.000_000_001)
  let assert InputOnly(partial_price) =
    pricing_harness.check_estimate(
      "provider-b",
      "input-only",
      Some(1000),
      Some(500),
      None,
    )
  assert float.loosely_equals(partial_price, 0.002, 0.000_000_001)
  let assert OutputOnly(valid_side) =
    pricing_harness.check_estimate(
      "provider-b",
      "negative-input",
      Some(1000),
      Some(500),
      None,
    )
  assert float.loosely_equals(valid_side, 0.002, 0.000_000_001)
  let assert InputOnly(zero_without_price) =
    pricing_harness.check_estimate(
      "provider-b",
      "cache-only",
      Some(0),
      None,
      None,
    )
  assert zero_without_price == 0.0
}
