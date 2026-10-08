defmodule Aiur.Events.IssueLogPersistenceCharacterizationTest do
  @moduledoc "Publisher-to-IssueLog persistence matrix (characterization)"

  use Aiur.TestSupport

  alias Aiur.Events.Publisher
  alias Aiur.{IssueLog, TrackerIdentity}

  # Deliberately green on main; pins existing behaviour for C2-T03 and MP-E4.
  @kinds [:emit, :emit_alert, :self, :consumed]

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    tmp = Path.dirname(Path.dirname(Application.fetch_env!(:aiur, :log_file)))
    identity = identity()
    assert String.starts_with?(IssueLog.event_log_path(identity), tmp <> "/")

    tracked_key = {Publisher, :tracked_fn}
    previous = :persistent_term.get(tracked_key, :unset)
    Publisher.set_tracked_fn(fn _number -> true end)

    on_exit(fn ->
      case previous do
        :unset -> :persistent_term.erase(tracked_key)
        value -> :persistent_term.put(tracked_key, value)
      end
    end)

    %{identity: identity}
  end

  test "joinable agent and ticket events reach history when a writer exists (characterization)", %{identity: identity} do
    writer = attach_writer(identity)
    [agent, pr, ci, _system] = publish_matrix(identity, identity: identity, issue_number: nil)
    :sys.get_state(writer)

    assert history(identity) == [with_kind(agent, "self"), with_kind(pr, "emit"), with_kind(ci, "emit")]
  end

  test "joinable events without a writer are not persisted (characterization)", %{identity: identity} do
    publish_matrix(identity, identity: identity, issue_number: nil)

    assert IssueLog.event_history(identity, kinds: @kinds) == {:error, :missing_source}
  end

  test "unattributed GitHub/CI-shaped events never reach history (characterization)", %{identity: identity} do
    writer = attach_writer(identity)
    publish_matrix(identity, issue_number: String.to_integer(identity.identifier))
    :sys.get_state(writer)

    assert history(identity) == []
  end

  test "an identity for another ticket is not persisted (characterization)", %{identity: identity} do
    writer = attach_writer(identity)
    other = %{identity | identifier: Integer.to_string(String.to_integer(identity.identifier) + 1)}
    other_writer = attach_writer(other)
    publish("ticket.#{identity.identifier}.pr.merged", identity: other, issue_number: nil)
    :sys.get_state(writer)
    :sys.get_state(other_writer)

    assert history(identity) == []
    assert history(other) == []
  end

  test "system topics never write a per-ticket marker (characterization)", %{identity: identity} do
    without_writer = identity()
    publish("system.main.branch.push", identity: without_writer, issue_number: nil)
    assert IssueLog.event_history(without_writer, kinds: @kinds) == {:error, :missing_source}

    writer = attach_writer(identity)
    publish("system.main.branch.push", identity: identity, issue_number: nil)
    publish("system.main.branch.push", issue_number: String.to_integer(identity.identifier))
    sentinel = publish("ticket.#{identity.identifier}.pr.merged", identity: identity, issue_number: nil)
    :sys.get_state(writer)

    assert history(identity) == [with_kind(sentinel, "emit")]
  end

  defp publish_matrix(identity, opts) do
    ["ticket.#{identity.identifier}.agent.progress", "ticket.#{identity.identifier}.pr.merged", "ticket.#{identity.identifier}.ci.failed", "system.main.branch.push"]
    |> Enum.map(&publish(&1, opts))
  end

  defp publish(topic, opts) do
    assert {:ok, id, _subscribers} = Publisher.publish(topic, %{"n" => 1}, opts)
    {id, topic}
  end

  defp with_kind({id, topic}, kind), do: {id, topic, kind}

  defp history(identity) do
    assert {:ok, events} = IssueLog.event_history(identity, kinds: @kinds)
    Enum.map(events, &{&1.id, &1.topic, &1.kind})
  end

  defp attach_writer(identity) do
    :ok = IssueLog.attach(identity)
    event_path = IssueLog.event_log_path(identity)

    writer =
      IssueLog.Supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
      |> Enum.find(fn pid -> :sys.get_state(pid).event_path == event_path end)

    assert is_pid(writer)
    on_exit(fn -> Aiur.TestSupport.safe_stop(writer) end)
    writer
  end

  defp identity do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I-42",
      identifier: System.unique_integer([:positive]) |> Integer.to_string(),
      reason: nil
    }
  end
end
