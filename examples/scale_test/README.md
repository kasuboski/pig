# Scale Test — Digital Organism Ecosystem

[![Gleam](https://img.shields.io/badge/Gleam-1.0+-a67bf4)](https://gleam.run)
[![BEAM](https://img.shields.io/badge/BEAM-OTP-orange)](https://erlang.org)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A real-time ecosystem simulation demonstrating **pig** (the Gleam agent framework) running at scale on the BEAM VM. Thousands of independent agent processes make decisions via a local LLM, while a live SVG grid visualizes the emergent behavior through Lustre server components over WebSocket.

> This project pushes the boundaries of what's possible with agent-based systems on the BEAM — coordinating hundreds of LLM-powered agents in real-time with fault tolerance and efficient batching.

---

## 🌍 What It Does

The simulation runs a 50×50 grid where:

- **🌿 Plants** grow deterministically, spreading to adjacent cells
- **🐰 Herbivores** (AI agents) eat plants, flee predators, and reproduce
- **🐺 Predators** (AI agents) hunt herbivores and reproduce

Every organism controlled by the AI makes decisions by calling a local LLM (via ollama). The BEAM VM manages thousands of independent agent processes, with the scheduler batching up to 10 organisms per LLM call and running up to 8 concurrent requests. Everything is visualized in real-time as an interactive SVG grid.

---

## 🏗️ Architecture

```
main()
 ├── World Actor — 50×50 grid, 200ms ticks, owns all state
 │   ├── Maintains grid state (plants, herbivores, predators)
 │   ├── Runs deterministic simulation tick logic
 │   └── Broadcasts snapshots to direct subscribers
 │
 ├── Scheduler Actor — batched LLM calls
 │   ├── Queues agents needing new decisions
 │   ├── Batches up to 10 organisms per LLM prompt
 │   ├── Runs up to 8 concurrent LLM calls (configurable)
 │   ├── Provides food hints: [food:2NW], [prey:1S]
 │   └── Falls back to random intent on LLM failure
 └── Mist HTTP + WebSocket
     ├── Serves static assets and initial HTML
     ├── Handles WebSocket connections
     └── Each WS connection = one Lustre server component
         └── Subscribes directly to World actor for updates
```

---

## 🦎 Organisms

| Type | Agent? | Color | Behavior |
|------|--------|-------|----------|
| 🌿 Plant | No (world state) | <span style="color:#22c55e">Green (#22c55e)</span> | Spreads to adjacent cells, food for herbivores |
| 🐰 Herbivore | Yes (pig agent) | <span style="color:#3b82f6">Blue (#3b82f6)</span> | Eats plants, flees predators, reproduces |
| 🐺 Predator | Yes (pig agent) | <span style="color:#ef4444">Red (#ef4444)</span> | Hunts herbivores, reproduces |

---

## 🧠 How Agents Think

### The Decision Loop

1. **Intent Selection** — Each agent has a current `Intent` (Move/Eat/Reproduce/Rest/Wander)
2. **Deterministic Execution** — The simulation executes that intent every tick (200ms)
3. **Re-thinking** — When agents need new decisions, the scheduler batches them
4. **LLM Query** — Batches of up to 10 agents are sent to the LLM at once
5. **Intent Parsing** — LLM response is parsed into intents for each agent
6. **Fallback** — On any failure (timeout, parse error, ollama down): falls back to Wander

### Example Prompt

```
You are organisms in a 50x50 grid. Respond with one word per line: eat, north, south, east, west, reproduce, wander, rest.

1. H (23,45) e=42 N=plant S=empty E=empty W=empty [food:2NW]
2. P (12,8) e=95 N=empty S=herbivore E=empty W=empty [prey:1S]
3. H (44,22) e=18 N=plant S=plant E=empty W=plant [food:0N]
```

### Example Response

```
north
south
eat
```

Each line corresponds to the organism in the same position in the prompt.

### Food Hints

The scheduler scans radius 1-5 around each agent and adds hints to the prompt:
- `[food:2NW]` — Nearest plant is 2 steps north-west
- `[prey:1S]` — Nearest prey is 1 step south

This dramatically improves agent survival and interesting behavior.

---

## 🎮 Controls

| Control | Description |
|---------|-------------|
| **Pause/Resume** | Toggle the simulation |
| **Reset** | Restart with a fresh random population |
| **LLM Concurrency** | Slider (0-20, default 8) — Max concurrent LLM batch calls |

At concurrency 0, all agents use random fallback (no LLM calls). Higher values increase throughput but may overload your local ollama instance.

---

## 📊 Stats Bar

The bottom stats bar shows:
- **Tick counter** — How many simulation ticks have run
- **Organism counts** — Live counts by type (colored to match SVG)
- **Birth/Death totals** — Total births and deaths this session
- **LLM stats** — Total calls, successes, failures, and current queue size

---

## 🚀 Setup & Running

### Prerequisites

- [Gleam](https://gleam.run) (1.0+)
- [Erlang/OTP](https://erlang.org) (25+)
- [ollama](https://ollama.com) running locally with a model

### Installation

```bash
cd examples/scale_test
gleam deps install
```

### Configuration

Set environment variables for your LLM:

```bash
export OPENAI_COMPAT_BASE_URL=http://localhost:11434/v1
export OPENAI_COMPAT_API_KEY=ollama
export OPENAI_COMPAT_MODEL=your-model-name  # e.g., llama3.2, gemopuse4b
```

### Running

```bash
gleam run
```

Then open http://localhost:3000 in your browser.

---

## 📦 Dependencies

| Dependency | Purpose |
|------------|---------|
| `pig` (local path) | Agent framework — LLM integration |
| `lustre` | Server components for SVG rendering |
| `mist` | HTTP/WebSocket server |
| `wisp` | Web toolkit (used by mist) |
| `gleam_otp` | BEAM actors (World, Scheduler) |
| `gleam_erlang` | Erlang interop |
| `gleam_http` | HTTP types |
| `gleam_json` | JSON parsing for LLM responses |

---

## 🎯 Key Design Decisions

### Batched LLM Calls
Up to 10 organisms per prompt for throughput. This reduces network overhead and allows ollama to process multiple decisions in parallel.

### One-Shot Pig Agents
Each LLM call creates a fresh pig agent with no persistent conversation history. This keeps agents stateless and decisions context-independent (based only on current observation).

### Direct Subscriptions
The World actor maintains its own subscriber list rather than using `group_registry`. Each Lustre server component sends a `Subscribe(subject)` message on init, and the World broadcasts snapshots directly to all subscribers.

### Food Hints
The prompt includes nearest food/prey direction within radius 5. Without this, agents wander randomly and die quickly. With hints, they exhibit purposeful hunting and foraging behavior.

### Swap-Through-Plants
Animals can walk through plants by swapping positions (the plant moves to the animal's old position). This prevents gridlock and creates more dynamic movement.

### Unlinked Processes
LLM calls run in `spawn_unlinked` processes to prevent timeout crashes from propagating to the supervisor. If ollama hangs or times out, only that batch fails.

### Random Fallback
On any LLM failure (timeout, parse error, network issue), agents fall back to a random intent. This keeps the simulation running smoothly even when the LLM is unavailable.

---

## ⚖️ Simulation Balance

Current tuned parameters for interesting behavior:

| Parameter | Value |
|-----------|-------|
| **Grid size** | 50×50 (2,500 cells) |
| **Starting plants** | ~300 (12% coverage) |
| **Plant max energy** | 20 |
| **Plant energy decay** | -1 per tick |
| **Plant spread chance** | 5% per tick |
| **Starting herbivores** | 20 |
| **Herbivore starting energy** | 100 |
| **Herbivore energy decay** | -1 per tick |
| **Herbivore eat gain** | +10 |
| **Herbivore reproduce cost** | 10 |
| **Starting predators** | 5 |
| **Predator starting energy** | 120 |
| **Predator energy decay** | -1 per tick |
| **Predator eat gain** | +20 |
| **Predator reproduce cost** | 10 |
| **Tick duration** | 200ms |
| **LLM batch size** | 10 organisms |
| **Max LLM concurrency** | 8 (default, 0-20) |
| **LLM timeout** | 10 seconds |

With these settings, populations tend to stabilize after ~200 ticks with a dynamic balance of predators and prey.

---

## 📁 Project Structure

```
src/
├── scale_test.gleam              # Main entry, Mist server, WebSocket handler
└── scale_test/
    ├── ecosystem.gleam           # Lustre server component (SVG + controls)
    ├── grid.gleam                # Pure Dict-based grid operations
    ├── sim.gleam                 # Pure simulation tick logic
    ├── world.gleam               # World actor (grid owner, ticker, broadcaster)
    ├── scheduler.gleam           # LLM decision queue + batching
    ├── prompt.gleam                # LLM prompt builder (single + batch)
    ├── intent.gleam              # Intent types + response parser
    └── protocol.gleam            # Shared types (breaks import cycle)
```

---

## 🔧 Troubleshooting

### LLM Timeouts
If you see frequent LLM failures, try:
- Reducing the **LLM Concurrency** slider
- Using a faster model (e.g., `gemma2:2b` instead of `llama3.2`)
- Checking ollama is running: `curl http://localhost:11434/api/tags`

### No Organisms Appearing
- Check browser console for WebSocket errors
- Verify `OPENAI_COMPAT_MODEL` is set to an available ollama model
- Try setting concurrency to 0 to test with random fallback only

### High CPU Usage
- Reduce LLM concurrency slider
- Lower tick speed (requires code change to `schedule_tick`)

---

## 📝 License

MIT

---

## 🤝 Contributing

This is a demonstration project for the pig agent framework. Feel free to experiment with:
- Different LLM prompts in `prompt.gleam`
- Simulation balance parameters in `sim.gleam`
- New organism types and behaviors
- Visualization improvements in `ecosystem.gleam`
