//// Pure contract fixtures. No setup, callbacks, IO, or implementation calls.

import gleam/list
import gleam/option.{None, Some}
import otel/attribute.{type Value, IntValue, StringList, StringValue}
import otel/trace
import pig_otel.{ChatCompletions, Custom, Responses}
import pig_protocol/inference.{type InferenceMetadata, InferenceMetadata}
import pig_protocol/stop_reason

pub fn operations() -> List(
  #(pig_otel.Operation, String, trace.SpanKind, List(#(String, Value))),
) {
  [
    #(pig_otel.Run(None, "r1"), "invoke_agent", trace.Internal, [
      #("gen_ai.operation.name", StringValue("invoke_agent")),
      #("pig.run.id", StringValue("r1")),
    ]),
    #(
      pig_otel.Run(Some("planner"), "r2"),
      "invoke_agent planner",
      trace.Internal,
      [
        #("gen_ai.operation.name", StringValue("invoke_agent")),
        #("pig.run.id", StringValue("r2")),
        #("gen_ai.agent.name", StringValue("planner")),
      ],
    ),
    #(
      pig_otel.Inference(ChatCompletions, Some("openai"), Some("requested")),
      "chat requested",
      trace.Client,
      [
        #("gen_ai.operation.name", StringValue("chat")),
        #("gen_ai.provider.name", StringValue("openai")),
        #("gen_ai.request.model", StringValue("requested")),
        #("openai.api.type", StringValue("chat_completions")),
      ],
    ),
    #(
      pig_otel.Inference(Responses, Some("openai"), Some("requested")),
      "chat requested",
      trace.Client,
      [
        #("gen_ai.operation.name", StringValue("chat")),
        #("gen_ai.provider.name", StringValue("openai")),
        #("gen_ai.request.model", StringValue("requested")),
        #("openai.api.type", StringValue("responses")),
      ],
    ),
    #(pig_otel.Inference(Responses, None, None), "chat", trace.Client, [
      #("gen_ai.operation.name", StringValue("chat")),
      #("openai.api.type", StringValue("responses")),
    ]),
    #(
      pig_otel.Inference(ChatCompletions, Some("compatible"), None),
      "chat",
      trace.Client,
      [
        #("gen_ai.operation.name", StringValue("chat")),
        #("gen_ai.provider.name", StringValue("compatible")),
        #("openai.api.type", StringValue("chat_completions")),
      ],
    ),
    #(pig_otel.Inference(Custom, None, None), "chat", trace.Client, [
      #("gen_ai.operation.name", StringValue("chat")),
    ]),
    #(
      pig_otel.Inference(Custom, Some("anthropic"), Some("known")),
      "chat known",
      trace.Client,
      [
        #("gen_ai.operation.name", StringValue("chat")),
        #("gen_ai.provider.name", StringValue("anthropic")),
        #("gen_ai.request.model", StringValue("known")),
      ],
    ),
    #(
      pig_otel.Tool("weather", "call1"),
      "execute_tool weather",
      trace.Internal,
      [
        #("gen_ai.operation.name", StringValue("execute_tool")),
        #("gen_ai.tool.name", StringValue("weather")),
        #("gen_ai.tool.call.id", StringValue("call1")),
      ],
    ),
    #(
      pig_otel.HttpServer("/v1/chat/completions"),
      "POST /v1/chat/completions",
      trace.Server,
      [
        #("http.request.method", StringValue("POST")),
        #("http.route", StringValue("/v1/chat/completions")),
      ],
    ),
    #(pig_otel.HttpServer("/v1/responses"), "POST /v1/responses", trace.Server, [
      #("http.request.method", StringValue("POST")),
      #("http.route", StringValue("/v1/responses")),
    ]),
    #(pig_otel.HttpAttempt("primary"), "POST", trace.Client, [
      #("http.request.method", StringValue("POST")),
      #("pig.proxy.target.id", StringValue("primary")),
    ]),
  ]
}

pub fn responses() -> List(#(InferenceMetadata, List(#(String, Value)))) {
  let absent = InferenceMetadata(None, None, None, None, None, None)
  list.append(
    [
      #(absent, []),
      #(InferenceMetadata(..absent, response_id: Some("response1")), [
        #("gen_ai.response.id", StringValue("response1")),
      ]),
      #(InferenceMetadata(..absent, response_model: Some("actual")), [
        #("gen_ai.response.model", StringValue("actual")),
      ]),
      #(
        InferenceMetadata(
          ..absent,
          input_tokens: Some(100),
          output_tokens: Some(50),
          cached_input_tokens: Some(40),
        ),
        [
          #("gen_ai.usage.input_tokens", IntValue(100)),
          #("gen_ai.usage.output_tokens", IntValue(50)),
          #("gen_ai.usage.cache_read.input_tokens", IntValue(40)),
        ],
      ),
      #(
        InferenceMetadata(
          ..absent,
          input_tokens: Some(0),
          output_tokens: Some(0),
          cached_input_tokens: Some(0),
        ),
        [
          #("gen_ai.usage.input_tokens", IntValue(0)),
          #("gen_ai.usage.output_tokens", IntValue(0)),
          #("gen_ai.usage.cache_read.input_tokens", IntValue(0)),
        ],
      ),
      #(InferenceMetadata(..absent, cached_input_tokens: Some(40)), [
        #("gen_ai.usage.cache_read.input_tokens", IntValue(40)),
      ]),
      #(
        InferenceMetadata(
          ..absent,
          input_tokens: Some(-1),
          output_tokens: Some(-50),
          cached_input_tokens: Some(-40),
        ),
        [],
      ),
    ],
    list.map(
      [
        #(stop_reason.Stop, "stop"),
        #(stop_reason.Length, "length"),
        #(stop_reason.ToolUse, "tool_use"),
        #(stop_reason.Error, "error"),
        #(stop_reason.Unknown("private raw provider text"), "unknown"),
      ],
      fn(row) {
        #(InferenceMetadata(..absent, stop_reason: Some(row.0)), [
          #("gen_ai.response.finish_reasons", StringList([row.1])),
        ])
      },
    ),
  )
}

pub fn terminals() -> List(
  #(pig_otel.Outcome, trace.Status, List(#(String, Value))),
) {
  list.flatten([
    [
      #(pig_otel.Succeeded, trace.StatusUnset, [
        #("pig.outcome", StringValue("succeeded")),
      ]),
    ],
    list.map(
      [
        "timeout", "deadline_exceeded", "client_disconnected", "agent_stopped",
        "cancelled", "rate_limited", "authentication", "invalid_request",
        "provider_error", "transport_error", "tool_error", "tool_blocked",
        "tool_not_found", "invalid_arguments", "persistence_error",
        "callback_error", "process_exit", "http_error", "upstream_error",
        "downstream_error",
      ],
      fn(category) {
        #(pig_otel.Failed(category), trace.StatusError(None), [
          #("pig.outcome", StringValue("failed")),
          #("error.type", StringValue(category)),
        ])
      },
    ),
    list.map(
      [
        "",
        "Token private",
        "https://user:secret@host/path?q=secret",
        "Timeout",
        "raw exception",
      ],
      fn(category) {
        #(pig_otel.Failed(category), trace.StatusError(None), [
          #("pig.outcome", StringValue("failed")),
          #("error.type", StringValue("_OTHER")),
        ])
      },
    ),
    [
      #(pig_otel.Cancelled("deadline_exceeded"), trace.StatusError(None), [
        #("pig.outcome", StringValue("cancelled")),
        #("error.type", StringValue("deadline_exceeded")),
      ]),
      #(pig_otel.Cancelled("a raw private reason"), trace.StatusError(None), [
        #("pig.outcome", StringValue("cancelled")),
        #("error.type", StringValue("_OTHER")),
      ]),
    ],
  ])
}
