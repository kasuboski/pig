//// Knowledge Notebook — an example pig agent with a persistent workspace.
////
//// This agent is a biology study assistant. It reads source materials
//// from a SQLite-backed virtual filesystem, creates organized study
//// notes, and remembers what it has studied across sessions.
////
//// On first run, the workspace is seeded with biology reference texts.
//// On subsequent runs, the agent sees its previous notes and can
//// continue building on them.
////
//// ## Running
////
//// Set environment variables for your OpenAI-compatible provider.
//// You must use a model that supports function/tool calling:
////
////   OPENAI_COMPAT_BASE_URL=http://localhost:11434/v1
////   OPENAI_COMPAT_API_KEY=ollama
////   OPENAI_COMPAT_MODEL=llama3.1
////
//// Note: use a model with tool-calling support (e.g. llama3.1+, mistral,
//// qwen2.5, gpt-4o). Models without tool calling will hallucinate tool
//// usage in text instead of actually invoking tools.
////
//// Then:
////
////   cd examples/knowledge_notebook
////   gleam run

import gleam/io
import gleam/list
import gleam/result
import gleam/string
import pig
import pig/ai/error
import pig/ai/message
import pig/ai/openai
import pig/workspace
import envoy

// ── Source Content ───────────────────────────────────────────────────
// Pre-seeded reference texts for the agent to read and organize.

fn cell_theory_source() -> String {
  "# Cell Theory

Cell theory is one of the fundamental principles of biology. It was
developed in the 1830s by scientists Matthias Schleiden and Theodor
Schwann, and later refined by Rudolf Virchow in 1855.

## The Three Tenets

1. **All living organisms are composed of one or more cells.**
   Every living thing, from bacteria to blue whales, is made of cells.

2. **The cell is the basic unit of structure and organization in organisms.**
   Cells are the building blocks of life.

3. **All cells arise from pre-existing cells.**
   This tenet, added by Virchow, overturned the idea of spontaneous
   generation. Summarized as \"omnis cellula e cellula\".

## Key Figures

- **Matthias Schleiden** (1838): Concluded all plants are made of cells.
- **Theodor Schwann** (1839): Extended the conclusion to animals.
- **Rudolf Virchow** (1855): Proposed that cells come only from other cells."
}

fn mitosis_source() -> String {
  "# Mitosis

Mitosis is the process of cell division that produces two genetically
identical daughter cells from a single parent cell. It is essential
for growth, repair, and asexual reproduction.

## Stages of Mitosis

### 1. Prophase
- Chromatin condenses into visible chromosomes.
- The nuclear envelope begins to break down.
- Centrioles move to opposite poles and spindle fibers form.

### 2. Metaphase
- Chromosomes align at the cell's equatorial plate (metaphase plate).
- Each chromosome is attached to spindle fibers at its centromere.

### 3. Anaphase
- Sister chromatids are pulled apart toward opposite poles.
- The cell begins to elongate.

### 4. Telophase
- Chromatids reach the poles and decondense.
- Nuclear envelopes reform around each set of chromosomes.
- Spindle fibers break down.

### Cytokinesis (overlaps with telophase)
- The cytoplasm divides, forming two separate daughter cells.
- In animal cells, a cleavage furrow forms.
- In plant cells, a cell plate forms.

## Memory Aid
\"PMAT\" — **P**rophase, **M**etaphase, **A**naphase, **T**elophase"
}

fn photosynthesis_source() -> String {
  "# Photosynthesis

Photosynthesis is the process by which plants, algae, and some bacteria
convert light energy into chemical energy (glucose). The overall equation:

  6CO2 + 6H2O + light energy -> C6H12O6 + 6O2

## Light-Dependent Reactions
- Location: Thylakoid membranes of the chloroplast.
- Water molecules are split (photolysis), releasing oxygen.
- Light energy is captured by chlorophyll and converted to ATP and NADPH.
- Electrons pass through an electron transport chain.

## The Calvin Cycle (Light-Independent Reactions)
- Location: Stroma of the chloroplast.
- CO2 is fixed into organic molecules by the enzyme RuBisCO.
- ATP and NADPH from the light reactions power the conversion to G3P
  (a sugar precursor).
- G3P is used to build glucose and other carbohydrates.

## Key Terms
- **Chloroplast**: Organelle where photosynthesis occurs.
- **Chlorophyll**: Green pigment that absorbs light energy.
- **Stomata**: Pores on leaves that allow CO2 in and O2 out.
- **RuBisCO**: The most abundant enzyme on Earth; catalyzes carbon fixation."
}

// ── Workspace Seeding ────────────────────────────────────────────────

fn seed_workspace(ws: workspace.Workspace) -> Nil {
  case workspace.list_directory(ws, "/sources") {
    Ok(_) -> {
      io.println("📂 Workspace already contains data — skipping seed.")
      Nil
    }
    Error(_) -> {
      let _ = workspace.mkdir(ws, "/sources")
      let _ = workspace.write_file(
        ws,
        "/sources/cell_theory.md",
        cell_theory_source(),
      )
      let _ = workspace.write_file(ws, "/sources/mitosis.md", mitosis_source())
      let _ = workspace.write_file(
        ws,
        "/sources/photosynthesis.md",
        photosynthesis_source(),
      )
      let _ = workspace.remember(ws, "user_level", "beginner")
      let _ = workspace.remember(
        ws,
        "studied_topics",
        "cell_theory",
      )
      io.println("🌱 Seeded workspace with biology sources.")
    }
  }
}

// ── Workspace Display ────────────────────────────────────────────────

fn print_workspace_state(ws: workspace.Workspace) -> Nil {
  io.println("\n📂 Workspace contents:")

  // List top-level directories
  case workspace.list_directory(ws, "/") {
    Ok(entries) -> {
      list.each(entries, fn(entry) {
        io.println("  /" <> entry <> "/")
        // List children of each directory
        case workspace.list_directory(ws, "/" <> entry) {
          Ok(children) ->
            list.each(children, fn(child) {
              io.println("    " <> child)
            })
          Error(_) -> Nil
        }
      })
    }
    Error(_) -> io.println("  (empty)")
  }

  // List KV memory
  case workspace.list_keys(ws, "") {
    Ok(keys) -> {
      case keys {
        [] -> io.println("  (no memory keys)")
        _ -> {
          io.println("  Memory:")
          list.each(keys, fn(key) {
            let value =
              workspace.recall(ws, key)
              |> result.unwrap("(error)")
            io.println("    " <> key <> " = " <> value)
          })
        }
      }
    }
    Error(_) -> Nil
  }

  Nil
}

// ── System & User Prompts ────────────────────────────────────────────

fn system_prompt() -> String {
  "You are a biology study assistant. You have tools to read and write files "
    <> "and to store key-value memories. Use them to complete your tasks.\n\n"
    <> "IMPORTANT: You MUST call tools to do your work. Do not describe or "
    <> "narrate what you would do — actually call the tools.\n\n"
    <> "When writing study notes, include:\n"
    <> "- A clear title\n"
    <> "- A summary in your own words\n"
    <> "- Key terms with definitions\n"
    <> "- 2-3 review questions\n\n"
    <> "Be thorough but accessible. The user is a beginner."
}

fn user_prompt() -> String {
  "I'm studying biology and need your help organizing my notes. Please:\n\n"
    <> "1. Call list_directory with path \"/sources\" to see the reference materials\n"
    <> "2. Call read_file for each source to read the content\n"
    <> "3. Call recall with key \"studied_topics\" to check what I've already covered\n"
    <> "4. Call write_file to create organized study notes in /notes for each topic\n"
    <> "5. Call remember with key \"studied_topics\" to update what we studied today\n\n"
    <> "Start by calling list_directory now."
}

// ── Config ───────────────────────────────────────────────────────────

fn base_url() -> String {
  envoy.get("OPENAI_COMPAT_BASE_URL")
  |> result.unwrap("http://localhost:11434/v1")
}

fn api_key() -> String {
  envoy.get("OPENAI_COMPAT_API_KEY")
  |> result.unwrap("ollama")
}

fn model() -> String {
  envoy.get("OPENAI_COMPAT_MODEL")
  |> result.unwrap("llama3")
}

// ── Main ─────────────────────────────────────────────────────────────

pub fn main() {
  // Open (or create) the persistent workspace
  let assert Ok(ws) = workspace.open("./notebook.db")

  // Seed reference sources if this is a fresh workspace
  seed_workspace(ws)

  // Show what's persisted — demonstrates survival across sessions
  print_workspace_state(ws)

  let provider =
    openai.provider_with_base_url(api_key(), model(), base_url())

  // Register all 7 workspace tools in one call
  let cfg =
    pig.new(provider.call)
    |> pig.with_model("knowledge_notebook")
    |> pig.with_system_prompt(system_prompt())
    |> pig.with_tools(workspace.all_tools(ws))
    |> pig.with_terminal_output()

  let assert Ok(agent) = pig.start(cfg)

  io.println("\n🤖 Asking agent to organize study notes...\n")

  let result =
    pig.run_with_timeout(agent, user_prompt(), 120_000)

  case result {
    Ok(message.Assistant(content:, ..)) -> {
      io.println("\n=== Study Notes Created ===\n")
      io.println(content)
    }
    Ok(other) -> {
      io.println("\n⚠ Unexpected response:")
      io.println(string.inspect(other))
    }
    Error(error.Timeout) -> {
      io.println("\n⚠ Timed out waiting for the model to respond.")
      io.println("Try a faster model or increase the timeout.")
    }
    Error(error.ApiError(msg)) -> {
      io.println("\n⚠ API error: " <> msg)
    }
    Error(error.RateLimited) -> {
      io.println("\n⚠ Rate limited — wait a moment and try again.")
    }
    Error(error.InvalidResponse(detail)) -> {
      io.println("\n⚠ Invalid response from provider: " <> detail)
    }
  }

  // Show what the agent created in the workspace
  io.println("\n📂 Workspace after agent run:")
  print_workspace_state(ws)

  pig.stop(agent)
  let _ = workspace.close(ws)
}
