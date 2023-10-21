//// This module is a wrapper around the erlang [FS](https://fs.n2o.dev/)
//// library. It allows you to create a listener for file change events for any
//// operating system.
////
//// Note: on Linux and BSD, you need `inotify-tools` installed.

import gleam/option.{None, Option, Some}
import gleam/otp/actor.{ErlangStartResult}
import gleam/erlang/atom.{Atom}
import gleam/erlang/process
import gleam/dynamic
import gleam/string
import gleam/erlang/charlist
import gleam/result
import gleam/list

/// Possible filesystem events
pub type Event {
  Created
  Modified
  Closed
  Deleted
  Renamed
  Attribute
  Unknown(Atom)
}

/// A filesystem change
pub type Change {
  Change(path: String, events: List(Event))
}

/// Handler function called when an event is detected
pub type Handler =
  fn(String, Event) -> Nil

/// Handler function used with an actor handler
pub type ActorHandler(a) =
  fn(Change, a) -> actor.Next(Change, a)

/// Opaque builder type to instantiate the listener
///
/// Instantiate it with `new`.
pub opaque type Builder(a) {
  Builder(
    dirs: List(String),
    handler: Option(ActorHandler(a)),
    initial_state: Option(a),
  )
}

/// Create a new builder
///
/// Use this with the `add_dir` and `handler` functions to configure the
/// watcher
pub fn new() -> Builder(a) {
  Builder(dirs: [], handler: None, initial_state: None)
}

/// Add a directory to watch
///
/// # Examples
/// 
/// ```gleam
/// filespy.new()
/// |> filespy.add_dir("./watched")
/// ```
pub fn add_dir(builder: Builder(a), directory: String) -> Builder(a) {
  Builder(..builder, dirs: [directory, ..builder.dirs])
}

/// Set the handler
///
/// # Examples
///
/// ```gleam
/// filespy.new()
/// |> filespy.add_dir("./watched")
/// |> filespy.set_handler(fn (path: String, event: filespy.Event) {
///     case event {
///       filespy.Created -> {
///         io.println("File " <> path <> " created")
///       }
///       _ -> {
///         io.println("Something else happened to " <> path)
///       }
///   }
/// })
pub fn set_handler(builder: Builder(Nil), handler: Handler) -> Builder(Nil) {
  let wrapped_handler = fn(event: Change, _state: Nil) -> actor.Next(
    Change,
    Nil,
  ) {
    let Change(path, events) = event
    list.each(events, fn(ev) { handler(path, ev) })
    actor.continue(Nil)
  }
  Builder(..builder, handler: Some(wrapped_handler), initial_state: Some(Nil))
}

/// Set the actor handler
///
/// Use this if you want to have a more thorough control over the generated
/// actor. You will also need to set an initial state, with `set_initial_state`.
pub fn set_actor_handler(
  builder: Builder(a),
  handler: ActorHandler(a),
) -> Builder(a) {
  Builder(..builder, handler: Some(handler))
}

/// Set the initial state
///
/// Use this if you want to have a more thorough control over the generated
/// actor. You'll only have access to this state if you set your handler with
/// `set_actor_handler`.
pub fn set_initial_state(builder: Builder(a), state: a) -> Builder(a) {
  Builder(..builder, initial_state: Some(state))
}

@external(erlang, "fs", "start_link")
fn fs_start_link(name: Atom, path: String) -> ErlangStartResult

@external(erlang, "fs", "subscribe")
fn fs_subscribe(name: Atom) -> Atom

/// Converts an atom to an event
fn to_event(from: dynamic.Dynamic) -> Result(Event, List(dynamic.DecodeError)) {
  use event <- result.try(atom.from_dynamic(from))

  let created = atom.create_from_string("created")
  let deleted = atom.create_from_string("deleted")
  let modified = atom.create_from_string("modified")
  let closed = atom.create_from_string("closed")
  let renamed = atom.create_from_string("renamed")
  let attrib = atom.create_from_string("attribute")
  let removed = atom.create_from_string("removed")

  case event {
    ev if ev == created -> Ok(Created)
    ev if ev == deleted -> Ok(Deleted)
    ev if ev == modified -> Ok(Modified)
    ev if ev == closed -> Ok(Closed)
    ev if ev == renamed -> Ok(Renamed)
    ev if ev == removed -> Ok(Deleted)
    ev if ev == attrib -> Ok(Attribute)
    other -> Ok(Unknown(other))
  }
}

/// Get a `Selector` which can be used to select for filesystem events.
pub fn selector() -> process.Selector(Change) {
  process.new_selector()
  |> process.selecting_anything(fn(event) {
    let assert Ok(#(_pid, _, #(path, events))) =
      dynamic.tuple3(
        dynamic.dynamic,
        dynamic.dynamic,
        dynamic.tuple2(
          fn(l) {
            dynamic.unsafe_coerce(l)
            |> charlist.to_string
            |> Ok
          },
          dynamic.list(of: to_event),
        ),
      )(event)

    Change(path: path, events: events)
  })
}

/// Get an actor `Spec` for the watcher
pub fn spec(builder: Builder(a)) -> actor.Spec(a, Change) {
  let assert Some(handler) = builder.handler
  let assert Some(initial_state) = builder.initial_state

  actor.Spec(
    init: fn() {
      let #(oks, errs) =
        builder.dirs
        |> list.map(fn(dir) {
          let atom = atom.create_from_string("fs_watcher" <> dir)
          fs_start_link(atom, dir)
          |> result.map(fn(pid) { #(pid, atom) })
        })
        |> result.partition()

      case errs {
        [] -> {
          // all good!
          oks
          |> list.each(fn(res) {
            let #(_pid, atom) = res
            fs_subscribe(atom)
          })
          actor.Ready(initial_state, selector())
        }
        errs -> {
          list.each(
            oks,
            fn(res) {
              let #(pid, _atom) = res
              process.kill(pid)
            },
          )
          actor.Failed("Failed to start watcher: " <> string.inspect(errs))
        }
      }
    },
    init_timeout: 5000,
    loop: handler,
  )
}

/// Start an actor which will receive filesystem events
///
/// In order for this to work, you'll need to have set some directories to be
/// watched, with `add_dir`, and set a handler with either `set_handler` or
/// `set_actor_handler` and `set_initial_state`.
pub fn start(
  builder: Builder(a),
) -> Result(process.Subject(Change), actor.StartError) {
  spec(builder)
  |> actor.start_spec
}
