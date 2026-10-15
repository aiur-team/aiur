defmodule Aiur.IssueSyncTestSupport do
  @moduledoc false

  alias Aiur.{AlertLedger, Issue, TrackerIdentity}

  def issue(id, state) do
    %Issue{
      id: id,
      identifier: "its-everdred/aiur##{id}",
      title: "Issue #{id}",
      state: state,
      tracker_identity: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "node-#{id}",
        identifier: id,
        reason: nil
      }
    }
  end

  def control_agent(parent) do
    send(parent, {:agent_started, self()})
    control_agent_loop(parent)
  end

  def control_agent_loop(parent) do
    receive do
      message ->
        send(parent, message)
        control_agent_loop(parent)
    end
  end

  # The fake agent forwards messages in receive order. A marker sent after the
  # code under test therefore proves every earlier resume request was observed.
  def control_agent_barrier(agent) do
    ref = make_ref()
    send(agent, {:control_agent_barrier, ref})

    receive do
      {:control_agent_barrier, ^ref} -> :ok
    end
  end

  # IssueSync and Exchange publish synchronously from the test process. A
  # self-sent marker is ordered after every callback/event they emitted.
  def mailbox_barrier do
    ref = make_ref()
    send(self(), {:mailbox_barrier, ref})

    receive do
      {:mailbox_barrier, ^ref} -> :ok
    end
  end

  def running_agents(count, issue_state \\ nil) do
    for id <- 1..count, into: %{} do
      entry = if issue_state, do: %{issue: issue("live-#{id}", issue_state)}, else: %{}
      {"live-#{id}", entry}
    end
  end

  def dependency_paused_entry(blocker_identifier) do
    %{
      control: %{status: :paused},
      paused_reason: :blocker_dependency,
      blocker_pause: %{blocker_identifier: blocker_identifier}
    }
  end

  def write_central_attention!(topic) do
    log_path = AlertLedger.path()
    File.mkdir_p!(Path.dirname(log_path))

    File.write!(
      log_path,
      ~s({"event":"alert","timestamp":"2026-08-02T01:00:00Z","topic":"#{topic}","message":"persisted attention","needs_attention":true}\n)
    )
  end
end
