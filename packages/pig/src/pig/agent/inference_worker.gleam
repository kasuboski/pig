//// Owned relays between provider inferences and the agent runtime.
////
//// The provider coordinator remains the sole owner of provider terminality.
//// This worker owns the wait and forwards its ordered event stream without
//// blocking the runtime actor.

import gleam/erlang/process
import pig/provider
import pig_protocol/error

/// An owned inference relay. Its internals never escape the runtime.
pub opaque type Worker {
  Worker(commands: process.Subject(Command))
}

type Command {
  Cancel
}

type RelayMessage {
  ProviderEvent(provider.InferenceEvent)
}

type CoordinatorMessage {
  Relay(RelayMessage)
  CancelRequested
  RelayDown
  OwnerDown
}

/// Start an inference relay and return before provider work begins.
pub fn start(
  provider_instance: provider.Provider,
  request: provider.InferenceRequest,
  notify: fn(provider.InferenceEvent) -> Nil,
) -> Worker {
  let owner = process.self()
  let ready = process.new_subject()
  let _spawned =
    process.spawn_unlinked(fn() {
      let commands = process.new_subject()
      let relay_messages = process.new_subject()
      process.send(ready, commands)
      let relay =
        process.spawn_unlinked(fn() {
          let inference = provider.start(provider_instance, request)
          relay_provider(inference, relay_messages)
        })
      coordinator(
        commands,
        relay_messages,
        relay,
        process.monitor(relay),
        process.monitor(owner),
        notify,
      )
    })
  Worker(commands: process.receive_forever(ready))
}

/// Cancel provider work owned by this relay. Repeated calls are harmless.
pub fn cancel(worker: Worker) -> Nil {
  process.send(worker.commands, Cancel)
}

fn relay_provider(
  inference: provider.Inference,
  relay_messages: process.Subject(RelayMessage),
) -> Nil {
  case provider.receive_forever(inference) {
    event -> {
      process.send(relay_messages, ProviderEvent(event))
      case event {
        provider.Delta(_) -> relay_provider(inference, relay_messages)
        provider.Finished(_) -> hold_until_released()
      }
    }
  }
}

// Keep the relay alive after sending its terminal event. Otherwise its monitor
// can race that message and make the coordinator invent a second terminal.
fn hold_until_released() -> Nil {
  let release = process.new_subject()
  process.receive_forever(release)
}

fn coordinator(
  commands: process.Subject(Command),
  relay_messages: process.Subject(RelayMessage),
  relay: process.Pid,
  relay_monitor: process.Monitor,
  owner_monitor: process.Monitor,
  notify: fn(provider.InferenceEvent) -> Nil,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(relay_messages, Relay)
    |> process.select_map(commands, fn(_) { CancelRequested })
    |> process.select_specific_monitor(relay_monitor, fn(_) { RelayDown })
    |> process.select_specific_monitor(owner_monitor, fn(_) { OwnerDown })
  case process.selector_receive_forever(selector) {
    Relay(ProviderEvent(event)) -> {
      notify(event)
      case event {
        provider.Delta(_) ->
          coordinator(
            commands,
            relay_messages,
            relay,
            relay_monitor,
            owner_monitor,
            notify,
          )
        provider.Finished(_) -> process.kill(relay)
      }
    }
    CancelRequested | OwnerDown -> process.kill(relay)
    RelayDown ->
      notify(
        provider.Finished(
          Error(error.InvalidResponse(
            "Inference relay exited without a terminal event",
          )),
        ),
      )
  }
}
