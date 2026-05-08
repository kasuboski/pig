# Scale Test — Digital Organism Ecosystem

## What

A real-time ecosystem simulation demonstrating pig orchestrating up to **10,000 AI agents** on the BEAM. Herbivores (🐰) and predators (🐺) are pig agents that use a small LLM (ollama/gemma 4 e4b) to decide their next action. Plants (🌿) grow and spread deterministically. The ecosystem is visualized as a living grid via Lustre server components over WebSocket.

**The story**: BEAM runs 10,000 independent agent processes, each with its own state and LLM conversation history, while a deterministic simulation keeps the world ticking. A concurrency-limited scheduler queues LLM calls so ollama stays comfortable even at scale.

## Architecture

```
One Gleam project (Erlang target)

main()
 ├── group_registry (pub/sub between World → Lustre runtimes)
 ├── World Actor
 │     Owns 100×100 grid state
 │     Ticks deterministic simulation every ~200ms
 │     Broadcasts state changes to registry topic
 │     Tracks which agents need to re-think
 ├── Decision Scheduler Actor
 │     Priority queue of agents awaiting LLM decisions
 │     Configurable max concurrency
 │     Spawns a process per pig.run() call
 │     Parses LLM response → Intent → sends to World
 ├── Agent Registry Actor
 │     Lazy pig agent creation (on first think, not on spawn)
 │     Destruction when organism dies
 └── Mist HTTP + WebSocket
       Serves HTML + Lustre runtime JS
       One Lustre server component runtime per browser connection
       Each runtime subscribes to World via group_registry
```

## Project Structure

```
examples/scale_test/
├── gleam.toml
├── src/
│   ├── scale_test.gleam              # main entry point
│   └── scale_test/
│       ├── grid.gleam                # pure grid operations (Dict-based)
│       ├── sim.gleam                 # pure simulation tick logic
│       ├── world.gleam               # world actor (grid owner, ticker)
│       ├── scheduler.gleam           # LLM decision queue
│       ├── agent_registry.gleam      # pig agent lifecycle
│       ├── prompt.gleam              # prompt template construction
│       ├── intent.gleam              # LLM response → Intent parser
│       └── ecosystem.gleam           # Lustre server component (SVG view)
└── README.md
```

**Dependencies**: pig (local path), lustre (hex), mist (hex), wisp (hex), group_registry (hex), gleam_otp, gleam_erlang, gleam_http, gleam_json, envoy, filepath. **Only pig is a local dep.**

No omnimessage. No separate client or shared projects. Native Lustre server components render SVG server-side, and `group_registry` handles pub/sub between the World actor and connected browser runtimes — following the Lustre whiteboard publish-subscribe example pattern.

## Organisms

| Type | Agent? | Behavior |
|------|--------|----------|
| 🌿 Plant | No — World state only | Spreads to adjacent cells with low probability. Food for herbivores. |
| 🐰 Herbivore | Yes — pig agent | Eats plants, flees predators, reproduces when healthy. |
| 🐺 Predator | Yes — pig agent | Hunts herbivores, reproduces when healthy. |

Plants aren't pig agents — they don't think. Only 🐰 and 🐺 get pig agents, keeping the agent count manageable (~3000 max at 10k organisms).

## Intent System

The LLM and deterministic sim are **decoupled**:

1. Each agent stores a current **Intent**: `Move(Direction)`, `Eat`, `Reproduce`, `Rest`, or `Wander`
2. The deterministic sim follows that intent every tick — no LLM needed for physics
3. Periodically (or when something interesting happens), the agent "re-thinks" via an LLM call

**LLM prompt** (~60 tokens in, ~5 tokens out):
```
You are a herbivore at (45,23) energy:15/30.
Nearby: N=plant S=empty E=predator W=empty.
Current plan: moving north.
Respond with ONE word: north/south/east/west/eat/reproduce/rest/wander
```

**Response parsing**: string match (lowercase, trimmed) → Intent. Any unrecognized response defaults to `Wander`.

**When does an agent re-think?**
- Its intent was blocked (tried to move into occupied cell, tried to eat but nothing there)
- N ticks since last thought (configurable, default ~50)
- Something interesting nearby (herbivore sees predator, predator sees prey)

## Simulation Tick

Every ~200ms, the World actor runs:

1. **Execute intents** — for each organism, apply their intent deterministically (move, eat, reproduce, rest, wander)
2. **Energy decay** — all organisms lose 1 energy
3. **Death** — remove organisms with energy ≤ 0
4. **Plant growth** — existing plants may spread; empty cells may spontaneously sprout
5. **Determine re-thinks** — which agents need a new LLM decision
6. **Broadcast diff** — send only changed cells to connected UIs

## Scheduler

The Decision Scheduler manages the LLM call queue to avoid overwhelming ollama:

- **Priority queue**: urgent (predator adjacent) > blocked intent > routine re-think
- **Configurable concurrency** (default: 5 concurrent LLM calls)
- Each call spawns a process: `pig.run_with_timeout(agent, prompt, 10_000)`
- On success: parse response → send `UpdateIntent` to World
- On failure (timeout, parse error, API down): default to `Wander` — simulation never stops
- UI slider controls concurrency (0 = pure deterministic, 50 = aggressive)

## Visualization

**Lustre server component** renders SVG server-side. Connected browsers receive HTML patches via WebSocket.

**Grid appearance:**
- Dark background, fixed 100×100 SVG grid
- Each organism is a small colored rect or emoji
- 🌿 green, 🐰 blue, 🐺 red
- Brightness/opacity = energy level (dim = dying, bright = healthy)
- Pulsing glow = agent currently thinking (LLM call in flight)
- Fade out = death, pop in = birth
- Empty cells = transparent (not rendered)

**Controls (rendered in the same Lustre component):**
- Agent count slider (10 → 10,000)
- LLM concurrency slider (0 → 50)
- Tick speed slider
- Pause/Resume, Reset buttons

**Stats panel (live):**
- Alive counts by type (🐰 🐺 🌿)
- Births / Deaths
- LLM calls/sec, avg response time, queue depth
- Current tick number

## Lustre Server Component Pattern

Following the Lustre whiteboard publish-subscribe example:

- **`ecosystem.gleam`** is a `lustre.application(init, update, view)` 
- **`init`** receives the `group_registry` and subscribes to the "ecosystem" topic using `server_component.select`
- **World actor** broadcasts state diffs to the registry topic
- Each connected browser gets its own Lustre runtime instance
- The `update` function handles both client-side events (sliders) and server-pushed state changes
- The `view` function renders SVG + controls — Lustre diffs and patches automatically

## Agent Lifecycle

- **Spawn**: AgentData created in World, placed on grid. Pig agent NOT created yet.
- **First think**: Scheduler requests agent → Registry lazily creates pig agent (`pig.new(provider) |> pig.with_system_prompt(...) |> pig.start()`)
- **Subsequent thinks**: `pig.run(agent, prompt)` with accumulated history for context
- **Death**: Removed from World. Registry calls `pig.stop()`. Process cleaned up.
- **History pruning**: Keep last N messages to prevent prompts from growing unbounded

## Error Handling

| Failure | Response |
|---------|----------|
| Ollama down | All LLM calls fail → Wander. Simulation continues deterministically. Stats show 0 calls/sec. |
| Ollama slow (>5s) | Scheduler auto-reduces concurrency. Queue depth grows. |
| Pig agent crashes | Caught in scheduler, removed from registry, organism dies on grid. |
| Invalid LLM response | Parse fails → Wander. |
| WebSocket disconnect | Client reconnects. Lustre runtime restarted on reconnect. |

## Phases

### Phase 1: Skeleton — Random Decisions, No LLM
Boot server → open browser → see organisms moving on grid. All decisions are random. ~50 organisms on 100×100 grid.

- Project setup (single gleam project, deps from hex + pig)
- Pure grid and simulation logic
- World actor (tick timer, state owner)
- Scheduler (random intents only)
- Lustre server component with SVG view + basic controls
- Mist server with WebSocket
- **Delivers**: Working visual simulation, no LLM

### Phase 2: LLM Integration
Replace random decisions with real pig agents calling ollama.

- Config from env vars
- Prompt template builder
- Intent parser
- Agent registry (lazy pig agent creation)
- Real scheduler (priority queue, concurrency control, process spawning)
- Wire up: World tick → Scheduler → pig.run() → parse → UpdateIntent
- **Delivers**: Agents making LLM-driven decisions visible on grid

### Phase 3: Performance & Scale
Target 10,000 agents smoothly.

- Dirty-set diff tracking (only changed cells broadcast)
- Lazy pig agent creation (not on spawn, only on first think)
- Agent cap (excess agents use random intents)
- History pruning (keep last N messages)
- Rate limiting / backpressure
- **Delivers**: Smooth 10k agent simulation

### Phase 4: Polish
- Visual polish (emoji, energy brightness, thinking pulse, death fade)
- Full controls panel (sliders, pause, reset)
- Stats panel (live counters)
- Robust error handling (ollama down indicator, crash recovery)
- README
- **Delivers**: Presentation-ready example
