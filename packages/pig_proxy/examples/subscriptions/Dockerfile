# syntax=docker/dockerfile:1
FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang AS build

WORKDIR /build
COPY packages/pig_protocol/ packages/pig_protocol/
COPY packages/pig_transport/ packages/pig_transport/
COPY packages/pig_otel/ packages/pig_otel/
COPY packages/pig_proxy/ packages/pig_proxy/

WORKDIR /build/packages/pig_proxy/examples/subscriptions
RUN cd host && rebar3 compile
RUN gleam deps download \
    && gleam build --warnings-as-errors \
    && gleam export erlang-shipment
# Ship SDK runtime artifacts, not the Rebar build tools or dependency sources.
RUN mkdir -p /shipment/otel \
    && for dep in host/_build/default/lib/*; do \
         target=/shipment/otel/$(basename "$dep"); \
         mkdir -p "$target"; \
         cp -a "$dep/ebin" "$target/"; \
         if [ -d "$dep/priv" ]; then cp -a "$dep/priv" "$target/"; fi; \
       done

FROM erlang:29.0.3-slim AS runtime
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 pig \
    && useradd --uid 10001 --gid pig --create-home --shell /usr/sbin/nologin pig \
    && mkdir -p /home/pig/.pig \
    && chown pig:pig /home/pig/.pig

WORKDIR /app
COPY --from=build /build/packages/pig_proxy/examples/subscriptions/build/erlang-shipment/ /app/gleam/
COPY --from=build /shipment/otel/ /app/otel/
COPY --chmod=755 packages/pig_proxy/examples/subscriptions/docker-entrypoint.sh /app/entrypoint.sh

ENV HOME=/home/pig \
    PIG_PROXY_BIND=0.0.0.0 \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump
USER 10001:10001
EXPOSE 8080
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl --fail --silent --output /dev/null "http://127.0.0.1:${PIG_PROXY_PORT:-8080}/health"
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["host"]
