//// Child-VM orchestration in Gleam; only platform primitives are foreign.

import exception
import filepath
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/port.{type Port}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string
import simplifile

/// Executable and compiled module paths for an isolated host VM.
pub opaque type Context {
  Context(executable: String, args: List(String), example: String)
}

/// A child process owned by this process through its port.
pub opaque type Child {
  Child(port: Port)
}

type Event {
  Output(String)
  Exited(Int)
}

type Signal {
  Term
  Kill
}

type UniqueOption {
  Positive
  Monotonic
}

/// Resolve and load the example's compiled paths without starting the SDK.
pub fn context() -> Context {
  let example = find_example(module_directory())
  let gleam_paths = ebin_paths(filepath.join(example, "build/dev/erlang"))
  let host_paths = ebin_paths(filepath.join(example, "host/_build/default/lib"))
  add_paths(host_paths)
  let assert Ok(_) = ensure_started(atom.create("inets"))
  let assert Ok(_) = ensure_started(atom.create("mist"))
  let paths = list.append(gleam_paths, host_paths)
  let args = ["-noshell", ..list.flat_map(paths, fn(path) { ["-pa", path] })]
  Context(executable(), args, example)
}

/// Return the example directory for isolated test files.
pub fn example_dir(context: Context) -> String {
  context.example
}

/// Launch a child with explicit environment overrides; None unsets a variable.
pub fn start(
  context: Context,
  eval: String,
  env: List(#(String, Option(String))),
) -> Child {
  Child(start_ffi(
    context.executable,
    list.append(context.args, ["-eval", eval]),
    env,
  ))
}

/// Await the startup marker with a fixed overall deadline, not per-chunk waits.
pub fn await_ready(child: Child) -> Nil {
  await_marker(selector(child), "", now() + 10_000)
}

fn await_marker(
  events: process.Selector(Event),
  output: String,
  deadline: Int,
) -> Nil {
  case process.selector_receive(events, int.max(0, deadline - now())) {
    Error(_) -> panic as "subscriptions host startup timeout"
    Ok(Exited(_)) -> panic as "subscriptions host exited before ready"
    Ok(Output(chunk)) -> {
      let output = output <> chunk
      case contains_marker(output) {
        True -> Nil
        False -> await_marker(events, output, deadline)
      }
    }
  }
}

/// Collect output until the child exits within the overall deadline.
pub fn await_exit(child: Child, timeout: Int) -> #(Int, String) {
  collect(selector(child), "", now() + timeout)
}

fn collect(
  events: process.Selector(Event),
  output: String,
  deadline: Int,
) -> #(Int, String) {
  case process.selector_receive(events, int.max(0, deadline - now())) {
    Error(_) -> panic as "subscriptions child exit timeout"
    Ok(Output(chunk)) -> collect(events, output <> chunk, deadline)
    Ok(Exited(status)) -> #(status, output)
  }
}

/// Deliver SIGTERM to this live child only.
pub fn signal_term(child: Child) -> Nil {
  signal(child.port, Term)
}

/// Kill and close only this owned port's live child, even after assertion failure.
pub fn cleanup(child: Child) -> Nil {
  let _ = exception.rescue(fn() { signal(child.port, Kill) })
  close(child.port)
}

/// Reserve and release a loopback port for the child host to bind.
@external(erlang, "pig_subscriptions_acceptance_ffi", "free_port")
pub fn free_port() -> Int

/// Distinguish temporary test files without depending on real credentials.
pub fn unique_suffix() -> String {
  int.to_string(now())
  <> "-"
  <> int.to_string(unique_integer([Positive, Monotonic]))
}

fn selector(child: Child) -> process.Selector(Event) {
  process.new_selector()
  |> process.select_record(child.port, 1, fn(raw) {
    let outer = {
      use event <- decode.field(1, event_decoder())
      decode.success(event)
    }
    let assert Ok(event) = decode.run(raw, outer)
    event
  })
}

fn event_decoder() -> decode.Decoder(Event) {
  use tag <- decode.field(0, atom.decoder())
  case atom.to_string(tag) {
    "data" -> {
      use bytes <- decode.field(1, decode.bit_array)
      let assert Ok(output) = bit_array.to_string(bytes)
      decode.success(Output(output))
    }
    "exit_status" -> {
      use status <- decode.field(1, decode.int)
      decode.success(Exited(status))
    }
    _ -> decode.failure(Exited(-1), "child port event")
  }
}

fn find_example(directory: String) -> String {
  case
    simplifile.is_file(filepath.join(
      directory,
      "src/subscriptions/config.gleam",
    ))
  {
    Ok(True) -> directory
    _ -> {
      let parent = filepath.directory_name(directory)
      assert parent != directory
      find_example(parent)
    }
  }
}

fn ebin_paths(directory: String) -> List(String) {
  let assert Ok(entries) = simplifile.read_directory(directory)
  list.filter_map(entries, fn(entry) {
    let path = filepath.join(filepath.join(directory, entry), "ebin")
    case simplifile.is_directory(path) {
      Ok(True) -> Ok(path)
      _ -> Error(Nil)
    }
  })
}

@external(erlang, "pig_subscriptions_acceptance_ffi", "module_directory")
fn module_directory() -> String

@external(erlang, "pig_subscriptions_acceptance_ffi", "executable")
fn executable() -> String

@external(erlang, "pig_subscriptions_acceptance_ffi", "add_paths")
fn add_paths(paths: List(String)) -> Nil

@external(erlang, "pig_subscriptions_acceptance_ffi", "start")
fn start_ffi(
  executable: String,
  args: List(String),
  env: List(#(String, Option(String))),
) -> Port

@external(erlang, "pig_subscriptions_acceptance_ffi", "signal")
fn signal(port: Port, signal: Signal) -> Nil

@external(erlang, "pig_subscriptions_acceptance_ffi", "close")
fn close(port: Port) -> Nil

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

@external(erlang, "application", "ensure_all_started")
fn ensure_started(application: atom.Atom) -> Result(List(atom.Atom), Dynamic)

fn now() -> Int {
  monotonic_time(atom.create("millisecond"))
}

fn contains_marker(output: String) -> Bool {
  string.contains(output, "subscriptions host started")
}
