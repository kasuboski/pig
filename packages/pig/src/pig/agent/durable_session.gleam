//// Durable session commit and settings recovery transitions.
////
//// This module owns storage-facing recovery state so the runtime actor can
//// focus on run orchestration and message dispatch.

import gleam/list
import gleam/option
import pig/agent/state
import pig/provider.{type InferenceSettings}
import pig/session_store
import pig_protocol/error.{type AiError}
import pig_protocol/message.{type Message}

/// The result to apply after a durable agent-state commit.
@internal
pub type PostCommitDisposition {
  ResumeFromHistory
  ReturnMessage(Message)
  ReturnAiError(AiError)
}

/// Durable session state held by the runtime.
@internal
pub type SessionState {
  SessionDisabled
  SessionReady(store: session_store.SessionStore, head: option.Option(String))
  SessionPending(
    store: session_store.SessionStore,
    commit: session_store.SessionCommit,
    candidate: state.AgentState,
    disposition: PostCommitDisposition,
  )
  SessionSettingsPending(
    store: session_store.SessionStore,
    settings: InferenceSettings,
    mode: SettingsPendingMode,
  )
}

/// Recovery mode for a durable settings transition.
@internal
pub type SettingsPendingMode {
  RetryCommit(commit: session_store.SessionCommit)
  ReloadPending(conflict: session_store.SessionError)
  Reloaded(snapshot: session_store.Session)
}

/// A settings request can be rejected before storage is touched.
@internal
pub type SettingsRejection {
  CommitPending
  DifferentSettingsPending
}

/// The complete result of a settings transition.
@internal
pub type SettingsResult {
  SettingsResult(
    session: SessionState,
    agent_state: state.AgentState,
    inference_settings: InferenceSettings,
    outcome: Result(Nil, session_store.SessionError),
    rejection: option.Option(SettingsRejection),
  )
}

/// Commit the history delta produced by one pure agent transition.
@internal
pub fn commit_transition(
  session: SessionState,
  previous: state.AgentState,
  candidate: state.AgentState,
  disposition: PostCommitDisposition,
) -> Result(SessionState, #(SessionState, session_store.SessionError)) {
  let delta = list.drop(candidate.history, list.length(previous.history))
  case session, delta {
    SessionPending(..), _ | SessionSettingsPending(..), _ ->
      panic as "cannot commit while a session commit is pending"
    _, [] -> Ok(session)
    SessionDisabled, _ -> Ok(session)
    SessionReady(store:, head:), [first, ..rest] ->
      commit_messages(store, head, first, rest, candidate, disposition)
  }
}

fn commit_messages(
  store: session_store.SessionStore,
  head: option.Option(String),
  first: Message,
  rest: List(Message),
  candidate: state.AgentState,
  disposition: PostCommitDisposition,
) -> Result(SessionState, #(SessionState, session_store.SessionError)) {
  let session_store.SessionStore(commit: store_commit, ..) = store
  let commit = session_store.new_commit(head, first, rest)
  case store_commit(commit) {
    Ok(committed) ->
      accept_committed_session(store, commit, candidate, disposition, committed)
    Error(error) ->
      Error(#(SessionPending(store:, commit:, candidate:, disposition:), error))
  }
}

fn accept_committed_session(
  store: session_store.SessionStore,
  commit: session_store.SessionCommit,
  candidate: state.AgentState,
  disposition: PostCommitDisposition,
  committed: session_store.Session,
) -> Result(SessionState, #(SessionState, session_store.SessionError)) {
  case committed.head == option.Some(commit.id) {
    True -> Ok(SessionReady(store:, head: committed.head))
    False ->
      Error(#(
        SessionPending(store:, commit:, candidate:, disposition:),
        session_store.ParentConflict(
          expected: option.Some(commit.id),
          actual: committed.head,
        ),
      ))
  }
}

/// Retry a durable agent-state commit after a transient failure.
@internal
pub fn retry_pending(
  pending: SessionState,
) -> Result(
  #(state.AgentState, SessionState, PostCommitDisposition),
  #(SessionState, session_store.SessionError),
) {
  let assert SessionPending(store:, commit:, candidate:, disposition:) = pending
  let session_store.SessionStore(commit: store_commit, ..) = store
  case store_commit(commit) {
    Error(error) ->
      Error(#(SessionPending(store:, commit:, candidate:, disposition:), error))
    Ok(committed) ->
      case
        accept_committed_session(
          store,
          commit,
          candidate,
          disposition,
          committed,
        )
      {
        Ok(ready) -> Ok(#(candidate, ready, disposition))
        Error(error) -> Error(error)
      }
  }
}

/// Apply a requested settings change, including durable recovery.
@internal
pub fn set_settings(
  session: SessionState,
  agent_state: state.AgentState,
  default_settings: InferenceSettings,
  settings: InferenceSettings,
) -> SettingsResult {
  case session {
    SessionDisabled ->
      settings_result(session, agent_state, default_settings, Ok(Nil))
    SessionReady(store:, head:) ->
      commit_settings(agent_state, default_settings, store, head, settings)
    SessionPending(..) ->
      rejection_result(session, agent_state, default_settings, CommitPending)
    SessionSettingsPending(..) as pending ->
      retry_or_reject_settings(pending, agent_state, default_settings, settings)
  }
}

fn settings_result(
  session: SessionState,
  agent_state: state.AgentState,
  inference_settings: InferenceSettings,
  outcome: Result(Nil, session_store.SessionError),
) -> SettingsResult {
  SettingsResult(
    session:,
    agent_state:,
    inference_settings:,
    outcome:,
    rejection: option.None,
  )
}

fn rejection_result(
  session: SessionState,
  agent_state: state.AgentState,
  inference_settings: InferenceSettings,
  rejection: SettingsRejection,
) -> SettingsResult {
  SettingsResult(
    session:,
    agent_state:,
    inference_settings:,
    outcome: Ok(Nil),
    rejection: option.Some(rejection),
  )
}

fn commit_settings(
  agent_state: state.AgentState,
  default_settings: InferenceSettings,
  store: session_store.SessionStore,
  head: option.Option(String),
  settings: InferenceSettings,
) -> SettingsResult {
  let commit = session_store.new_settings_commit(head, settings)
  let session_store.SessionStore(commit: store_commit, ..) = store
  case store_commit(commit) {
    Error(error) ->
      settings_commit_error(
        agent_state,
        default_settings,
        store,
        head,
        commit,
        settings,
        error,
      )
    Ok(committed) ->
      case committed.head == option.Some(commit.id) {
        True ->
          settings_result(
            SessionReady(store:, head: committed.head),
            agent_state,
            default_settings,
            Ok(Nil),
          )
        False ->
          reload_settings(
            agent_state,
            default_settings,
            store,
            settings,
            session_store.ParentConflict(
              expected: option.Some(commit.id),
              actual: committed.head,
            ),
          )
      }
  }
}

fn retry_or_reject_settings(
  session: SessionState,
  agent_state: state.AgentState,
  default_settings: InferenceSettings,
  settings: InferenceSettings,
) -> SettingsResult {
  let assert SessionSettingsPending(store:, settings: pending_settings, mode:) =
    session
  case pending_settings == settings {
    False ->
      rejection_result(
        session,
        agent_state,
        default_settings,
        DifferentSettingsPending,
      )
    True ->
      case mode {
        RetryCommit(commit) ->
          retry_settings_commit(
            agent_state,
            default_settings,
            store,
            settings,
            commit,
          )
        ReloadPending(conflict) ->
          reload_settings(
            agent_state,
            default_settings,
            store,
            settings,
            conflict,
          )
        Reloaded(snapshot) ->
          retry_reloaded_settings(
            agent_state,
            default_settings,
            store,
            settings,
            snapshot,
          )
      }
  }
}

fn retry_settings_commit(
  agent_state: state.AgentState,
  default_settings: InferenceSettings,
  store: session_store.SessionStore,
  settings: InferenceSettings,
  commit: session_store.SessionCommit,
) -> SettingsResult {
  let session_store.SessionStore(commit: store_commit, ..) = store
  case store_commit(commit) {
    Error(error) ->
      settings_commit_error(
        agent_state,
        default_settings,
        store,
        commit.parent,
        commit,
        settings,
        error,
      )
    Ok(committed) ->
      case committed.head == option.Some(commit.id) {
        True ->
          settings_result(
            SessionReady(store:, head: committed.head),
            agent_state,
            default_settings,
            Ok(Nil),
          )
        False ->
          reload_settings(
            agent_state,
            default_settings,
            store,
            settings,
            session_store.ParentConflict(
              expected: option.Some(commit.id),
              actual: committed.head,
            ),
          )
      }
  }
}

fn settings_commit_error(
  agent_state: state.AgentState,
  default_settings: InferenceSettings,
  store: session_store.SessionStore,
  head: option.Option(String),
  commit: session_store.SessionCommit,
  settings: InferenceSettings,
  error: session_store.SessionError,
) -> SettingsResult {
  case error {
    session_store.ParentConflict(..) ->
      reload_settings(agent_state, default_settings, store, settings, error)
    session_store.InvalidCommit(_) | session_store.Corrupt(_) ->
      settings_result(
        SessionReady(store:, head:),
        agent_state,
        default_settings,
        Error(error),
      )
    session_store.Unavailable(_) ->
      settings_result(
        SessionSettingsPending(store:, settings:, mode: RetryCommit(commit:)),
        agent_state,
        default_settings,
        Error(error),
      )
  }
}

fn reload_settings(
  agent_state: state.AgentState,
  default_settings: InferenceSettings,
  store: session_store.SessionStore,
  settings: InferenceSettings,
  conflict: session_store.SessionError,
) -> SettingsResult {
  let session_store.SessionStore(load:, ..) = store
  case load() {
    Ok(snapshot) -> {
      let active_settings = persisted_settings(snapshot, default_settings)
      let replaced_state = replace_agent_state(agent_state, snapshot)
      settings_result(
        SessionSettingsPending(store:, settings:, mode: Reloaded(snapshot:)),
        replaced_state,
        active_settings,
        Error(conflict),
      )
    }
    Error(error) ->
      settings_result(
        SessionSettingsPending(
          store:,
          settings:,
          mode: ReloadPending(conflict:),
        ),
        agent_state,
        default_settings,
        Error(error),
      )
  }
}

fn replace_agent_state(
  agent_state: state.AgentState,
  snapshot: session_store.Session,
) -> state.AgentState {
  state.AgentState(
    ..agent_state,
    history: state.strip_system_messages(snapshot.messages),
    iterations: 0,
  )
}

fn persisted_settings(
  snapshot: session_store.Session,
  default_settings: InferenceSettings,
) -> InferenceSettings {
  case snapshot.inference_settings {
    option.Some(settings) -> settings
    option.None -> default_settings
  }
}

fn retry_reloaded_settings(
  agent_state: state.AgentState,
  default_settings: InferenceSettings,
  store: session_store.SessionStore,
  settings: InferenceSettings,
  snapshot: session_store.Session,
) -> SettingsResult {
  case snapshot.inference_settings {
    option.Some(loaded_settings) if loaded_settings == settings ->
      settings_result(
        SessionReady(store:, head: snapshot.head),
        agent_state,
        loaded_settings,
        Ok(Nil),
      )
    option.Some(_) | option.None ->
      commit_settings(
        agent_state,
        default_settings,
        store,
        snapshot.head,
        settings,
      )
  }
}
