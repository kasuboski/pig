# Pig Chat Example

A real-time chat application with AI agent personas. Pick an agent, send messages, and get AI-powered responses streamed back over WebSocket.

![Pig Chat Demo](assets/chat.png)

Three agents are available:

- **Elara the Elf** — A wise high elf who speaks in archaic prose about magic and nature
- **Marketing Maven** — A seasoned marketing expert who analyzes everything through a business lens
- **Project Maven** — An organized project manager who structures ideas into action plans

## Architecture

```
┌──────────────┐     WebSocket      ┌──────────────┐     HTTP      ┌──────────┐
│   Browser    │ ◄───────────────►  │   Server     │ ◄──────────►  │ LLM API  │
│  (Lustre JS) │   /omni-app-ws     │ (Mist/Wisp)  │               │ (OpenAI) │
└──────────────┘                    └──────────────┘               └──────────┘
```

- **shared/** — Common types and JSON encode/decode (used by both client and server)
- **client/** — Lustre frontend (JavaScript target) with omnimessage WebSocket transport
- **server/** — Wisp/Mist backend with pig agent orchestration, serving the frontend as static files

The server uses [Omnimessage](https://github.com/nickjohnso/omnimessage) for real-time state sync between the Lustre frontend and server-side Lustre server components. AI responses are generated using [Pig](../../) agents.

## Incremental Runs

Each accepted prompt starts exactly one `pig.stream_owned` run. The server waits for Pig to accept the run before committing the application user message or creating the assistant placeholder. If agent lookup or run startup is rejected, the server sends `ServerRemoveChatMessage` for the optimistic pending user message; no rejected user message is added to application history. After acceptance, the server forwards each `InferenceDelta(TextDelta)` as a transient `ServerAssistantDelta` event. The browser appends those fragments to the same placeholder ID, so the visible message grows without creating one message per token.

A run can contain several inference/tool rounds. Deltas from every round use the same placeholder. The placeholder is never written to the server application context. When the run emits `Completed`, the server takes the canonical final assistant message from the `RunEvent`, replaces the placeholder with that final message, and only then adds it to context. `Failed` and `Cancelled` remove the transient placeholder and do not persist partial assistant output.

`stream_owned` watches the server-component owner. If that owner goes away because the browser/component connection disconnects, Pig cancels the run with `ClientDisconnected`. The relay keeps run handles, event subjects, and process monitors local to the stream worker; none are placed in the chat model or durable message context.

## Build & Run

### Prerequisites

- [Gleam](https://gleam.run/) >= 1.5.1
- [Bun](https://bun.sh/) (installed automatically by lustre_dev_tools)
- An OpenAI-compatible LLM API (e.g. [Ollama](https://ollama.com), OpenAI, etc.)

The chat example also has local path dependencies on the Omnimessage repositories. From this checkout those repositories must exist at `knowledge/repos/omnimessage`.

### 1. Build the client

```bash
cd client
gleam run -m lustre/dev build
```

### 2. Copy static assets to the server

```bash
cp client/dist/client.js server/priv/static/client.mjs
cp client/build/packages/lustre/priv/static/lustre-server-component.mjs server/priv/static/
```

### 3. Build the server

```bash
cd server
gleam build
```

### 4. Run the server

Set environment variables for your LLM provider and start:

```bash
export OPENAI_COMPAT_BASE_URL=http://localhost:11434/v1  # Ollama default
export OPENAI_COMPAT_API_KEY=ollama
export OPENAI_COMPAT_MODEL=llama3

cd server
gleam run
```

Open [http://localhost:8000](http://localhost:8000) in your browser.

## Pig Features Demonstrated

| Feature | Where |
|---------|-------|
| **Agent creation** with system prompts | `server/agents.gleam` — each persona gets a `pig.new()` with a custom system prompt |
| **OpenAI-compatible provider** | `server/agents.gleam` — uses `openai.provider_with_base_url()` to connect to any OpenAI-compatible API |
| **Agent lifecycle** | `server/context.gleam` — pig agents are started lazily per persona and stored in an OTP actor |
| **Incremental RunEvent handling** | `server/components/chat.gleam` — maps `InferenceDelta(TextDelta)` to one stable transient placeholder and commits only `Completed` |
| **Disconnect cancellation** | `server/components/chat.gleam` — starts `pig.stream_owned()` with the server-component owner |
| **Shared stream protocol** | `shared/src/shared.gleam` — carries deltas and transient placeholder removal without exposing run subjects or PIDs |
| **Client accumulation** | `client/src/client/chat.gleam` — applies each delta to the existing placeholder ID and replaces it with the canonical final message |
| **Multiple inference/tool rounds** | `server/components/chat.gleam` — ignores round boundaries for UI identity while forwarding every text delta |
| **Error handling** | `server/components/chat.gleam` — rejects pending user messages on Busy/start errors and removes transient assistant output on failed or cancelled runs |
