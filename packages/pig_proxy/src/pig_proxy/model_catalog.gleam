//// Live models.dev-backed catalog for proxy cost accounting and metadata.
////
//// The catalog actor periodically fetches `https://models.dev/api.json` and
//// exposes a flat map of model slugs to `ModelInfo`. The metrics endpoint
//// uses this to compute per-request cost from token counts.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import logging
import pig_proxy/hackney

/// Pricing and context metadata for a single model slug.
pub type ModelInfo {
  ModelInfo(
    input_price: Option(Float),
    output_price: Option(Float),
    cache_read_price: Option(Float),
    cache_write_price: Option(Float),
    tiers: List(CostTier),
    context_limit: Option(Int),
    output_limit: Option(Int),
    tool_call: Bool,
    structured_output: Bool,
  )
}

/// A cost result that cannot represent a total unless both token sides are known.
/// UnknownTier means tiered pricing cannot be safely resolved from usage.
pub type Estimate {
  Unknown
  UnknownTier
  InputOnly(input: Float)
  OutputOnly(output: Float)
  Complete(input: Float, output: Float, total: Float)
}

/// A flat catalog keyed by model slug (e.g. "openai/gpt-4o").
pub opaque type Catalog {
  Catalog(models: Dict(String, ModelInfo))
}

/// Small immutable request-scoped projection of only routed model prices.
pub opaque type Pricing {
  Pricing(catalog: Catalog)
}

/// Create an empty catalog with no model entries.
pub fn empty() -> Catalog {
  Catalog(dict.new())
}

/// Messages handled by the catalog actor.
pub type CatalogMsg {
  Refresh
  RefreshComplete(result: Result(Catalog, String))
  GetCatalog(reply_to: process.Subject(Catalog))
}

const refresh_timeout_ms = 30_000

type CatalogState {
  CatalogState(
    catalog: Catalog,
    cache_key: Option(process.Name(CatalogMsg)),
    url: String,
    refresh_ms: Int,
    subject: process.Subject(CatalogMsg),
  )
}

/// Start the catalog actor.
///
/// It immediately schedules a refresh and re-fetches every `refresh_ms`
/// milliseconds. If a fetch or parse fails, the previous catalog is kept.
pub fn start(
  url: String,
  refresh_ms: Int,
) -> Result(process.Subject(CatalogMsg), actor.StartError) {
  let result =
    actor.new_with_initialiser(5000, initialise(url, refresh_ms, None))
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Start the catalog actor registered under `name`, returning the `Started`
/// value a supervisor needs, so the /metrics endpoint reaches the current
/// process after a restart.
pub fn start_named(
  url: String,
  refresh_ms: Int,
  name: process.Name(CatalogMsg),
) -> Result(actor.Started(process.Subject(CatalogMsg)), actor.StartError) {
  actor.new_with_initialiser(5000, initialise(url, refresh_ms, Some(name)))
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

/// Non-blocking snapshot scoped to one runtime's stable catalog name.
/// Reads do not call the actor or copy the catalog through a mailbox.
@external(erlang, "pig_proxy_model_catalog_cache_ffi", "cached")
pub fn cached(name: process.Name(CatalogMsg)) -> Catalog

@external(erlang, "pig_proxy_model_catalog_cache_ffi", "publish")
fn publish(name: process.Name(CatalogMsg), catalog: Catalog) -> Nil

/// Synchronously read the current catalog snapshot.
pub fn snapshot(subject: process.Subject(CatalogMsg)) -> Catalog {
  actor.call(subject, waiting: 5000, sending: fn(reply_to) {
    GetCatalog(reply_to)
  })
}

/// Pin pricing for the requested model across routed providers. This keeps
/// mailbox messages small and makes one inference immune to catalog refreshes.
pub fn pin(catalog: Catalog, identities: List(#(String, String))) -> Pricing {
  let models =
    list.fold(identities, dict.new(), fn(models, identity) {
      let slug = identity.0 <> "/" <> identity.1
      case dict.get(catalog.models, slug) {
        Ok(info) -> dict.insert(models, slug, info)
        Error(_) -> models
      }
    })
  Pricing(Catalog(models))
}

/// Estimate using a request-scoped pricing projection.
pub fn estimate_pinned(
  pricing: Pricing,
  provider: String,
  model: String,
  input_tokens: Option(Int),
  output_tokens: Option(Int),
  cached_input_tokens: Option(Int),
) -> Estimate {
  let Pricing(catalog) = pricing
  estimate(
    catalog,
    provider,
    model,
    input_tokens,
    output_tokens,
    cached_input_tokens,
  )
}

/// Look up a model by slug in a catalog.
pub fn find(catalog: Catalog, slug: String) -> Option(ModelInfo) {
  case dict.get(catalog.models, slug) {
    Ok(info) -> Some(info)
    Error(_) -> None
  }
}

/// Estimate request cost in USD from token counts and model pricing.
///
/// Prices are per-million tokens. Missing prices are treated as zero.
///
/// OpenAI usage counts `input_tokens` inclusively: cached tokens are a
/// subset of the input total, not an addition. The cached portion is
/// billed at `cache_read_price` when the catalog has one, falling back to
/// the full input price otherwise; the remainder is billed at `input_price`.
pub fn cost_usd(
  info: ModelInfo,
  input_tokens: Int,
  output_tokens: Int,
  cached_input_tokens: Int,
) -> Float {
  let cached = int.clamp(cached_input_tokens, 0, input_tokens)
  let uncached = input_tokens - cached
  let input_cost = case info.input_price {
    Some(price) -> int.to_float(uncached) *. price /. 1_000_000.0
    None -> 0.0
  }
  let cached_cost = case info.cache_read_price {
    Some(price) -> int.to_float(cached) *. price /. 1_000_000.0
    // No cache price catalogued: charge cached tokens at the input price
    // rather than reporting them as free.
    None ->
      case info.input_price {
        Some(price) -> int.to_float(cached) *. price /. 1_000_000.0
        None -> 0.0
      }
  }
  let output_cost = case info.output_price {
    Some(price) -> int.to_float(output_tokens) *. price /. 1_000_000.0
    None -> 0.0
  }
  input_cost +. cached_cost +. output_cost
}

/// Estimate USD costs for an exact provider/model identity and optional usage.
///
/// Missing usage or price leaves that side unknown. Cached tokens are included
/// within input usage; absent cache usage means zero cached tokens. Negative
/// counts make the whole estimate unknown; a negative price makes that side
/// unknown. Context tier thresholds are strict: usage greater than the declared
/// `size` uses that tier, while usage exactly at the boundary uses base rates.
/// Without input usage, or when any tier is unrecognized or malformed, tiered
/// models return `UnknownTier` rather than a base-rate estimate.
pub fn estimate(
  catalog: Catalog,
  provider: String,
  model: String,
  input_tokens: Option(Int),
  output_tokens: Option(Int),
  cached_input_tokens: Option(Int),
) -> Estimate {
  case has_negative_usage(input_tokens, output_tokens, cached_input_tokens) {
    True -> Unknown
    False -> {
      let slug = provider <> "/" <> model
      case dict.get(catalog.models, slug) {
        Error(_) -> Unknown
        Ok(info) -> {
          let selected = select_rates(info, input_tokens)
          case selected {
            Error(_) -> UnknownTier
            Ok(rates) -> {
              let cached = option.unwrap(cached_input_tokens, 0)
              let input_cost = case input_tokens {
                Some(tokens) -> {
                  let cached = int.clamp(cached, 0, tokens)
                  let uncached = tokens - cached
                  let cached_price = case rates.cache_read {
                    Some(price) -> Some(price)
                    None -> rates.input
                  }
                  case
                    price_tokens(uncached, rates.input),
                    price_tokens(cached, cached_price)
                  {
                    Some(uncached_cost), Some(cached_cost) -> {
                      let cost = uncached_cost +. cached_cost
                      Some(cost /. 1_000_000.0)
                    }
                    _, _ -> None
                  }
                }
                None -> None
              }
              let output_cost = case output_tokens {
                Some(tokens) ->
                  price_tokens(tokens, rates.output)
                  |> option.map(fn(cost) { cost /. 1_000_000.0 })
                None -> None
              }
              case input_cost, output_cost {
                Some(input), Some(output) ->
                  Complete(input, output, input +. output)
                Some(input), None -> InputOnly(input)
                None, Some(output) -> OutputOnly(output)
                None, None -> Unknown
              }
            }
          }
        }
      }
    }
  }
}

fn select_rates(
  info: ModelInfo,
  input_tokens: Option(Int),
) -> Result(PricingRates, Nil) {
  let has_unsupported_tier =
    list.fold(info.tiers, False, fn(found, tier) {
      case tier {
        UnsupportedTier -> True
        ContextTier(..) -> found
      }
    })
  case has_unsupported_tier {
    True -> Error(Nil)
    False ->
      case info.tiers, input_tokens {
        [], _ ->
          Ok(PricingRates(
            info.input_price,
            info.output_price,
            info.cache_read_price,
          ))
        _, None -> Error(Nil)
        tiers, Some(tokens) -> {
          let tier =
            list.fold(tiers, None, fn(selected, candidate) {
              choose_tier(selected, candidate, tokens)
            })
          case tier {
            Some(ContextTier(_, input, output, cache_read)) ->
              Ok(PricingRates(input, output, cache_read))
            Some(UnsupportedTier) -> Error(Nil)
            None ->
              Ok(PricingRates(
                info.input_price,
                info.output_price,
                info.cache_read_price,
              ))
          }
        }
      }
  }
}

fn price_tokens(tokens: Int, price: Option(Float)) -> Option(Float) {
  case tokens, price {
    0, _ -> Some(0.0)
    _, Some(price) if price >=. 0.0 -> Some(int.to_float(tokens) *. price)
    _, _ -> None
  }
}

fn choose_tier(
  selected: Option(CostTier),
  candidate: CostTier,
  tokens: Int,
) -> Option(CostTier) {
  case candidate {
    UnsupportedTier -> Some(UnsupportedTier)
    ContextTier(threshold, _, _, _) ->
      case selected {
        None if tokens > threshold -> Some(candidate)
        Some(ContextTier(current_threshold, _, _, _))
          if tokens > threshold && threshold > current_threshold
        -> Some(candidate)
        _ -> selected
      }
  }
}

fn has_negative_usage(
  input_tokens: Option(Int),
  output_tokens: Option(Int),
  cached_input_tokens: Option(Int),
) -> Bool {
  case input_tokens, output_tokens, cached_input_tokens {
    Some(input), _, _ if input < 0 -> True
    _, Some(output), _ if output < 0 -> True
    _, _, Some(cached) if cached < 0 -> True
    _, _, _ -> False
  }
}

/// Parse a models.dev JSON response into a flat catalog.
pub fn parse(json: String) -> Result(Catalog, json.DecodeError) {
  json.parse(from: json, using: catalog_decoder())
}

// ── Actor internals ─────────────────────────────────────────────

fn initialise(
  url: String,
  refresh_ms: Int,
  cache_key: Option(process.Name(CatalogMsg)),
) -> fn(process.Subject(CatalogMsg)) ->
  Result(
    actor.Initialised(CatalogState, CatalogMsg, process.Subject(CatalogMsg)),
    String,
  ) {
  fn(subject) {
    case cache_key {
      Some(name) -> publish(name, empty())
      None -> Nil
    }
    // Schedule the first refresh immediately so the catalog populates
    // without waiting for the full refresh interval.
    let _ = process.send_after(subject, 0, Refresh)

    actor.initialised(CatalogState(
      catalog: empty(),
      url:,
      refresh_ms:,
      subject:,
      cache_key:,
    ))
    |> actor.returning(subject)
    |> Ok
  }
}

fn handle_message(
  state: CatalogState,
  msg: CatalogMsg,
) -> actor.Next(CatalogState, CatalogMsg) {
  case msg {
    Refresh -> {
      // Run the HTTP fetch in a spawned process so the actor stays
      // responsive to snapshot queries while models.dev is slow.
      let _ =
        process.spawn(fn() {
          process.send(state.subject, RefreshComplete(do_refresh(state)))
        })
      actor.continue(state)
    }

    RefreshComplete(result) -> {
      let new_catalog = case result {
        Ok(catalog) -> {
          case state.cache_key {
            Some(name) -> publish(name, catalog)
            None -> Nil
          }
          catalog
        }
        Error(reason) -> {
          logging.log(logging.Warning, "model_catalog: " <> reason)
          state.catalog
        }
      }
      let new_state = CatalogState(..state, catalog: new_catalog)
      let _ =
        process.send_after(new_state.subject, new_state.refresh_ms, Refresh)
      actor.continue(new_state)
    }

    GetCatalog(reply_to) -> {
      process.send(reply_to, state.catalog)
      actor.continue(state)
    }
  }
}

fn do_refresh(state: CatalogState) -> Result(Catalog, String) {
  case hackney.sync_request("GET", state.url, [], "", refresh_timeout_ms) {
    hackney.OkResponse(status: 200, body:, ..) -> {
      case bit_array.to_string(body) {
        Ok(json_text) -> {
          case parse(json_text) {
            Ok(catalog) -> Ok(catalog)
            Error(e) ->
              Error(
                "failed to parse models.dev response: " <> string.inspect(e),
              )
          }
        }
        Error(_) -> Error("upstream response body is not valid UTF-8")
      }
    }

    hackney.OkResponse(status:, ..) ->
      Error("models.dev returned status " <> int.to_string(status))

    hackney.ErrorResponse(reason:) ->
      Error("failed to fetch models.dev: " <> reason)
  }
}

// ── JSON decoding ───────────────────────────────────────────────

/// A decoded context-price tier, or an unrecognized tier that makes estimates unknown.
pub opaque type CostTier {
  ContextTier(
    threshold: Int,
    input: Option(Float),
    output: Option(Float),
    cache_read: Option(Float),
  )
  UnsupportedTier
}

type PricingRates {
  PricingRates(
    input: Option(Float),
    output: Option(Float),
    cache_read: Option(Float),
  )
}

type CostFields {
  CostFields(
    input: Option(Float),
    output: Option(Float),
    cache_read: Option(Float),
    cache_write: Option(Float),
    tiers: List(CostTier),
  )
}

type LimitFields {
  LimitFields(context: Option(Int), output: Option(Int))
}

fn catalog_decoder() -> decode.Decoder(Catalog) {
  decode.dict(decode.string, provider_decoder())
  |> decode.map(fn(providers) {
    let models =
      dict.fold(providers, dict.new(), fn(acc, provider, entries) {
        dict.fold(entries, acc, fn(models, slug, info) {
          let qualified_slug = case string.split(slug, "/") {
            [own_provider, ..] if own_provider == provider -> slug
            _ -> provider <> "/" <> slug
          }
          dict.insert(models, qualified_slug, info)
        })
      })
    Catalog(models: add_bare_aliases(models))
  })
}

/// Index every qualified slug under its bare model name too for legacy lookups.
/// Exact provider/model estimates never use these aliases.
fn add_bare_aliases(
  models: Dict(String, ModelInfo),
) -> Dict(String, ModelInfo) {
  dict.fold(models, models, fn(acc, slug, info) {
    case string.split(slug, "/") {
      [_, name] -> dict.insert(acc, name, info)
      _ -> acc
    }
  })
}

fn provider_decoder() -> decode.Decoder(Dict(String, ModelInfo)) {
  use models <- decode.field(
    "models",
    decode.dict(decode.string, model_info_decoder()),
  )
  decode.success(models)
}

fn model_info_decoder() -> decode.Decoder(ModelInfo) {
  use cost <- decode.optional_field(
    "cost",
    CostFields(None, None, None, None, []),
    cost_decoder(),
  )
  use limit <- decode.optional_field(
    "limit",
    LimitFields(None, None),
    limit_decoder(),
  )
  use tool_call <- decode.optional_field("tool_call", False, decode.bool)
  use structured_output <- decode.optional_field(
    "structured_output",
    False,
    decode.bool,
  )

  decode.success(ModelInfo(
    input_price: cost.input,
    output_price: cost.output,
    cache_read_price: cost.cache_read,
    cache_write_price: cost.cache_write,
    tiers: cost.tiers,
    context_limit: limit.context,
    output_limit: limit.output,
    tool_call:,
    structured_output:,
  ))
}

fn cost_decoder() -> decode.Decoder(CostFields) {
  use input <- decode.optional_field("input", None, optional_number_decoder())
  use output <- decode.optional_field("output", None, optional_number_decoder())
  use cache_read <- decode.optional_field(
    "cache_read",
    None,
    optional_number_decoder(),
  )
  use cache_write <- decode.optional_field(
    "cache_write",
    None,
    optional_number_decoder(),
  )
  use tiers <- decode.optional_field(
    "tiers",
    [],
    decode.list(cost_tier_decoder()),
  )
  decode.success(CostFields(input:, output:, cache_read:, cache_write:, tiers:))
}

fn cost_tier_decoder() -> decode.Decoder(CostTier) {
  use input <- decode.optional_field("input", None, optional_number_decoder())
  use output <- decode.optional_field("output", None, optional_number_decoder())
  use cache_read <- decode.optional_field(
    "cache_read",
    None,
    optional_number_decoder(),
  )
  use threshold <- decode.field("tier", context_tier_threshold_decoder())
  decode.success(case threshold {
    Some(size) -> ContextTier(size, input, output, cache_read)
    None -> UnsupportedTier
  })
}

fn context_tier_threshold_decoder() -> decode.Decoder(Option(Int)) {
  use tier_type <- decode.field("type", decode.string)
  use size <- decode.optional_field("size", None, decode.optional(decode.int))
  decode.success(case tier_type, size {
    "context", Some(threshold) -> Some(threshold)
    _, _ -> None
  })
}

fn limit_decoder() -> decode.Decoder(LimitFields) {
  use context <- decode.optional_field(
    "context",
    None,
    decode.optional(decode.int),
  )
  use output <- decode.optional_field(
    "output",
    None,
    decode.optional(decode.int),
  )
  decode.success(LimitFields(context:, output:))
}

fn optional_number_decoder() -> decode.Decoder(Option(Float)) {
  decode.one_of(decode.map(decode.float, Some), or: [
    decode.map(decode.int, fn(n) { Some(int.to_float(n)) }),
  ])
}
