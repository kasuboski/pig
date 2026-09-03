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
    context_limit: Option(Int),
    output_limit: Option(Int),
    tool_call: Bool,
    structured_output: Bool,
  )
}

/// A flat catalog keyed by model slug (e.g. "openai/gpt-4o").
pub opaque type Catalog {
  Catalog(models: Dict(String, ModelInfo))
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
    actor.new_with_initialiser(5000, initialise(url, refresh_ms))
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
  actor.new_with_initialiser(5000, initialise(url, refresh_ms))
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

/// Synchronously read the current catalog snapshot.
pub fn snapshot(subject: process.Subject(CatalogMsg)) -> Catalog {
  actor.call(subject, waiting: 5000, sending: fn(reply_to) {
    GetCatalog(reply_to)
  })
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

/// Parse a models.dev JSON response into a flat catalog.
pub fn parse(json: String) -> Result(Catalog, json.DecodeError) {
  json.parse(from: json, using: catalog_decoder())
}

// ── Actor internals ─────────────────────────────────────────────

fn initialise(
  url: String,
  refresh_ms: Int,
) -> fn(process.Subject(CatalogMsg)) ->
  Result(
    actor.Initialised(CatalogState, CatalogMsg, process.Subject(CatalogMsg)),
    String,
  ) {
  fn(subject) {
    // Schedule the first refresh immediately so the catalog populates
    // without waiting for the full refresh interval.
    let _ = process.send_after(subject, 0, Refresh)

    actor.initialised(CatalogState(
      catalog: empty(),
      url:,
      refresh_ms:,
      subject:,
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
        Ok(catalog) -> catalog
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

type CostFields {
  CostFields(
    input: Option(Float),
    output: Option(Float),
    cache_read: Option(Float),
    cache_write: Option(Float),
  )
}

type LimitFields {
  LimitFields(context: Option(Int), output: Option(Int))
}

fn catalog_decoder() -> decode.Decoder(Catalog) {
  decode.dict(decode.string, provider_decoder())
  |> decode.map(fn(providers) {
    let models =
      providers
      |> dict.values
      |> list.fold(dict.new(), dict.merge)
    Catalog(models: add_bare_aliases(models))
  })
}

/// Index every `provider/model` slug under its bare model name too, so
/// lookups without a provider prefix (e.g. local or unknown providers)
/// still resolve. When two providers share a bare name the last one
/// inserted wins — collisions are rare in the models.dev catalog.
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
    CostFields(None, None, None, None),
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
  decode.success(CostFields(input:, output:, cache_read:, cache_write:))
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
