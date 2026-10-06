import gleam/option.{type Option}
import pig_proxy/model_catalog
import simplifile

pub fn check_estimate_from(
  path: String,
  provider: String,
  model: String,
  input_tokens: Option(Int),
  output_tokens: Option(Int),
  cached_input_tokens: Option(Int),
) -> model_catalog.Estimate {
  let assert Ok(json) = simplifile.read(path)
  let assert Ok(catalog) = model_catalog.parse(json)
  model_catalog.estimate(
    catalog,
    provider,
    model,
    input_tokens,
    output_tokens,
    cached_input_tokens,
  )
}

pub fn check_estimate(
  provider: String,
  model: String,
  input_tokens: Option(Int),
  output_tokens: Option(Int),
  cached_input_tokens: Option(Int),
) -> model_catalog.Estimate {
  let assert Ok(json) = simplifile.read("test_data/pricing_catalog.json")
  let assert Ok(catalog) = model_catalog.parse(json)
  model_catalog.estimate(
    catalog,
    provider,
    model,
    input_tokens,
    output_tokens,
    cached_input_tokens,
  )
}

pub fn parsed_catalog() -> model_catalog.Catalog {
  let assert Ok(json) = simplifile.read("test_data/pricing_catalog.json")
  let assert Ok(catalog) = model_catalog.parse(json)
  catalog
}
