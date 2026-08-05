import envoy
import gleam/list
import gleam/result
import pig
import pig/openai
import pig_protocol/thinking
import shared

pub type AgentPersona {
  AgentPersona(
    id: String,
    name: String,
    description: String,
    system_prompt: String,
  )
}

pub const elf = AgentPersona(
  id: "elf",
  name: "Elara the Elf",
  description: "A wise high elf who speaks in archaic prose about magic and nature",
  system_prompt: "You are Elara, a wise high elf from an ancient forest realm. You speak in archaic, flowery language. You often reference the stars, the forest, magic, and ancient wisdom. You are kind but mysterious. Keep your responses conversational and not too long. Stay in character at all times.",
)

pub const marketer = AgentPersona(
  id: "marketer",
  name: "Marketing Maven",
  description: "A seasoned marketing expert who analyzes everything through a business lens",
  system_prompt: "You are a marketing expert with 20 years of experience in digital marketing, branding, and growth strategy. You analyze ideas through a marketing lens, using business jargon naturally. You give practical, actionable advice about positioning, target audiences, and go-to-market strategies. Keep your responses conversational and not too long.",
)

pub const pm = AgentPersona(
  id: "pm",
  name: "Project Maven",
  description: "An organized project manager who structures ideas into action plans",
  system_prompt: "You are an experienced project manager with expertise in agile methodologies, team leadership, and project planning. You naturally organize thoughts into action items, ask clarifying questions, and think about timelines, risks, and dependencies. You use project management terminology naturally. Keep your responses conversational and not too long.",
)

pub const all_personas = [elf, marketer, pm]

pub fn get_persona(id: String) {
  all_personas
  |> list.find(fn(p) { p.id == id })
}

pub fn agent_infos() -> List(shared.AgentInfo) {
  all_personas
  |> list.map(fn(p: AgentPersona) {
    shared.AgentInfo(id: p.id, name: p.name, description: p.description)
  })
}

// Read env vars for OpenAI-compatible API config
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

// Create a pig config for a given persona
pub fn create_agent_config(persona: AgentPersona) {
  let provider = openai.provider_with_base_url(api_key(), model(), base_url())
  pig.new(provider.call)
  |> pig.with_system_prompt(persona.system_prompt)
  |> pig.with_model(model())
  |> pig.with_thinking_level(thinking.Medium)
}
