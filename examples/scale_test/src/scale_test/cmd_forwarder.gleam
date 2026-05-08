//// CMD forwarder — bridges WorldCmd -> WorldMsg to break the import cycle.
//// The scheduler sends WorldCmd, the world receives WorldMsg.
//// This tiny actor translates between them.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import scale_test/protocol.{type WorldCmd, UpdateIntent, UpdateLLMStats}
import scale_test/world.{
  type WorldMsg, UpdateIntent as UpdateWorldIntent,
  UpdateLLMStats as UpdateWorldLLMStats,
}

pub fn start(
  world: Subject(WorldMsg),
) -> actor.StartResult(Subject(WorldCmd)) {
  actor.new_with_initialiser(5000, fn(self) {
    actor.initialised(world)
      |> actor.returning(self)
      |> Ok
  })
  |> actor.on_message(fn(world, msg) {
    case msg {
      UpdateIntent(pos, intent) -> {
        process.send(world, UpdateWorldIntent(pos, intent))
        actor.continue(world)
      }
      UpdateLLMStats(llm_calls:, llm_errors:, llm_queue:, llm_in_flight:) -> {
        process.send(world, UpdateWorldLLMStats(llm_calls:, llm_errors:, llm_queue:, llm_in_flight:))
        actor.continue(world)
      }
    }
  })
  |> actor.start
}
