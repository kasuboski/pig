#!/usr/bin/env python3
"""Verify actual otelcol-contrib file-exporter JSON from subscriptions acceptance."""
import json
import sys
from pathlib import Path


def attributes(items):
    result = {}
    for item in items:
        value = item.get("value", {})
        if "stringValue" in value:
            decoded = value["stringValue"]
        elif "intValue" in value:
            decoded = int(value["intValue"])
        elif "doubleValue" in value:
            decoded = float(value["doubleValue"])
        elif "boolValue" in value:
            decoded = value["boolValue"]
        else:
            decoded = value
        result[item["key"]] = decoded
    return result


def main(path):
    spans = []
    for line in Path(path).read_text().splitlines():
        batch = json.loads(line)
        for resource_spans in batch.get("resourceSpans", []):
            resource = attributes(resource_spans.get("resource", {}).get("attributes", []))
            for scope_spans in resource_spans.get("scopeSpans", []):
                for span in scope_spans.get("spans", []):
                    spans.append({
                        **span,
                        "attributes": attributes(span.get("attributes", [])),
                        "resource": resource,
                    })
    assert len(spans) == 12, f"expected 12 actual collector spans, got {len(spans)}"
    assert all(s["resource"].get("service.name") == "pig-proxy-subscriptions" for s in spans)
    assert all(s.get("events", []) == [] and s.get("links", []) == [] for s in spans)
    groups = {}
    for span in spans:
        groups.setdefault(span["traceId"].lower(), []).append(span)
    expected = {
        "00000000000000000000000000000011": (
            "/v1/responses", "chat", "fake-codex", "collector-session", None
        ),
        "00000000000000000000000000000012": (
            "/v1/responses", "chat", "fake-codex", None, "collector-conversation"
        ),
        "00000000000000000000000000000021": (
            "/v1/chat/completions", "chat", "fake-zai", "collector-same", "collector-same"
        ),
        "00000000000000000000000000000022": (
            "/v1/chat/completions", "chat", "fake-zai", "café ☃", "separate-☃"
        ),
    }
    assert set(groups) == set(expected), f"unexpected trace IDs: {set(groups)}"
    for trace_id, (route, operation, model, session_id, conversation_id) in expected.items():
        group = groups[trace_id]
        assert len(group) == 3, (trace_id, len(group))
        server = next(s for s in group if s["attributes"].get("http.route") == route)
        logical = next(s for s in group if s["attributes"].get("gen_ai.operation.name") == operation)
        attempt = next(s for s in group if "pig.proxy.target.id" in s["attributes"])
        assert server["parentSpanId"].lower() == "1111111111111111"
        assert logical["parentSpanId"] == server["spanId"]
        assert attempt["parentSpanId"] == logical["spanId"]
        attrs = logical["attributes"]
        for span in group:
            span_attrs = span["attributes"]
            if session_id is None:
                assert "session.id" not in span_attrs
            else:
                assert span_attrs.get("session.id") == session_id
            if span is not logical:
                assert "gen_ai.conversation.id" not in span_attrs
            assert "unknown.private" not in span_attrs
        if conversation_id is None:
            assert "gen_ai.conversation.id" not in attrs
        else:
            assert attrs.get("gen_ai.conversation.id") == conversation_id
        assert attrs["gen_ai.request.model"] == model
        assert attrs["gen_ai.response.model"] == model
        assert attrs["gen_ai.usage.input_tokens"] == 11
        assert attrs["gen_ai.usage.output_tokens"] == 7
        assert attrs["gen_ai.usage.cache_read.input_tokens"] == 3
        assert attrs["pig.cost.provenance"] == "models_dev_estimate"
        assert abs(attrs["gen_ai.usage.input_cost"] - 0.0000175) < 1e-12
        assert abs(attrs["gen_ai.usage.output_cost"] - 0.00007) < 1e-12
        assert abs(attrs["gen_ai.usage.total_cost"] - 0.0000875) < 1e-12
        for span in group:
            assert not any(key.startswith("gen_ai.input") or key.startswith("gen_ai.output") for key in span["attributes"])
    print(f"Verified {len(spans)} actual collector spans across {len(groups)} traces: exact parentage, usage/cost, metadata-only privacy.")


if __name__ == "__main__":
    main(sys.argv[1])
