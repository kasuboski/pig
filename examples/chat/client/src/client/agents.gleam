import gleam/list

import lustre_pipes/attribute
import lustre_pipes/element
import lustre_pipes/element/html
import lustre_pipes/event

import shared.{type AgentId, type AgentInfo}

pub type Msg {
  UserSelectAgent(AgentId)
}

pub fn agent_selection_view(agents: List(AgentInfo)) -> element.Element(Msg) {
  html.div()
  |> attribute.class("h-full flex flex-col items-center justify-center gap-8 p-8")
  |> element.children([
    html.h1()
      |> attribute.class("text-3xl font-bold text-gray-800")
      |> element.text_content("Choose Your Agent"),
    html.p()
      |> attribute.class("text-gray-500")
      |> element.text_content("Select an AI agent to start chatting"),
    html.div()
      |> attribute.class("grid grid-cols-1 md:grid-cols-3 gap-6 max-w-4xl w-full")
      |> element.children(
        agents |> list.map(agent_card),
      ),
  ])
}

fn agent_card(agent: AgentInfo) -> element.Element(Msg) {
  let emoji = case agent.id {
    "elf" -> "🧝"
    "marketer" -> "📊"
    "pm" -> "📋"
    _ -> "🤖"
  }

  html.div()
  |> attribute.class(
    "border border-gray-200 rounded-xl p-6 flex flex-col items-center gap-4 hover:shadow-lg transition-shadow bg-white",
  )
  |> element.children([
    html.div()
      |> attribute.class("text-5xl")
      |> element.text_content(emoji),
    html.h2()
      |> attribute.class("text-xl font-semibold text-gray-700")
      |> element.text_content(agent.name),
    html.p()
      |> attribute.class("text-gray-500 text-center text-sm")
      |> element.text_content(agent.description),
    html.button()
      |> attribute.class(
        "mt-2 bg-blue-600 text-white px-6 py-2 rounded-lg font-medium hover:bg-blue-700 transition-colors",
      )
      |> event.on_click(UserSelectAgent(agent.id))
      |> element.text_content("Start Chat"),
  ])
}
