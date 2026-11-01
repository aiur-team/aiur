defmodule AiurWeb.Build.ConversationSource.Wave0bEventsTest do
  # The reads behind the event rows must keep "nothing happened" apart from
  # "could not read", and must never show other tickets' events as this one's.
  use Aiur.TestSupport

  alias Aiur.IssueLog.Paths
  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TrackerIdentity
  alias AiurWeb.Build.ConversationEvents
  alias AiurWeb.Build.ConversationSource.Wave0bEvents

  setup do
    original = Application.get_env(:aiur, :log_file)
    original_state_dir = Application.get_env(:aiur, :runtime_state_dir)
    tmp = Aiur.TestSupport.tmp_root!("conversation-events")
    Application.put_env(:aiur, :log_file, Path.join(tmp, "log/aiur.log"))
    Application.put_env(:aiur, :runtime_state_dir, Path.join(tmp, "state"))

    on_exit(fn ->
      if original, do: Application.put_env(:aiur, :log_file, original), else: Application.delete_env(:aiur, :log_file)
      if original_state_dir, do: Application.put_env(:aiur, :runtime_state_dir, original_state_dir), else: Application.delete_env(:aiur, :runtime_state_dir)
      Aiur.TestCleanup.rm_rf!(tmp)
    end)

    # The real log reader, routed through the stub table because this test starts no endpoint.
    EndpointStubs.scope(build_events_log_fun: &Wave0bEvents.log/2, build_events_merges_fun: fn -> [] end, build_events_decisions_fun: fn _ -> {:ok, []} end)
    :ok
  end

  defp write_log(id, lines) do
    path = Aiur.IssueLog.event_log_path(id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp identity(id), do: %TrackerIdentity{status: :joinable, kind: :github, owner: "acme", repository: "aiur", provider_id: "I_#{id}", database_id: String.to_integer(id), identifier: id, reason: nil}

  defp write_durable_log(identity, lines) do
    path = Paths.timeline_event_log_path(identity)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  defp rows(id) do
    {:ok, facts} = Wave0bEvents.read(%{id: id}, [])
    {:ok, rows} = facts.log
    ConversationEvents.from_log(rows, id, %{})
  end

  test "E2 events delivered to this agent from other tickets are not shown" do
    id = "#{System.unique_integer([:positive])}"

    write_log(id, [
      "2026-10-07T21:13:20Z [event:consumed] id=1 ticket.99.agent.progress: theirs",
      "2026-10-07T21:13:21Z [event:self] id=2 ticket.99.agent.blocked: theirs too",
      "2026-10-07T21:13:21Z [event:consumed] id=4 ticket.#{id}.agent.blocked: delivered copy",
      "2026-10-07T21:13:22Z [event:self] id=3 ticket.#{id}.agent.blocked: ours"
    ])

    assert [%{id: "ev:log:3", label: "Blocked", sub: "ours"}] = rows(id)
  end

  test "E15 an agent-written summary is redacted before any row is built" do
    id = "#{System.unique_integer([:positive])}"
    token = "ghp_" <> String.duplicate("a", 36)
    write_log(id, ["2026-10-07T21:13:20Z [event:self] id=1 ticket.#{id}.agent.blocked: token #{token} & <b>x</b>"])
    [%{sub: sub}] = rows(id)
    refute sub =~ token
    assert sub =~ "& <b>x</b>"
  end

  test "E8 a missing log is empty, an unreadable log is reported" do
    id = "#{System.unique_integer([:positive])}"
    assert {:ok, %{log: {:error, :missing_source}}} = Wave0bEvents.read(%{id: id}, [])

    path = Aiur.IssueLog.event_log_path(id)
    File.mkdir_p!(path)
    assert {:ok, %{log: {:error, {:unavailable, :eisdir}}}} = Wave0bEvents.read(%{id: id}, [])
  end

  test "E21 a decision store that exits is unavailable, not \"no question\"" do
    EndpointStubs.scope(build_events_decisions_fun: fn _ -> exit(:down) end, build_events_merges_fun: fn -> exit(:down) end)
    assert {:ok, %{decisions: :unavailable, merges: :unavailable}} = Wave0bEvents.read(%{id: "12"}, [])

    %{tail: tail} = ConversationEvents.current_facts(%{"id" => "12", "agent" => %{"state" => "command"}}, %{decisions: :unavailable, merges: :unavailable})
    assert [%{ev: "cmd", label: "Asked a blocking question", at: nil}] = tail
  end

  test "feed history survives rotating the per-run log directory" do
    id = "#{System.unique_integer([:positive])}"
    identity = identity(id)
    write_log(id, ["2026-10-07T21:13:20Z [event:self] id=1 ticket.#{id}.agent.blocked: run-only history"])

    earlier_events =
      for event_id <- 2..506 do
        "2026-10-07T21:13:20Z [event:self] id=#{event_id} ticket.#{id}.agent.progress: earlier progress"
      end

    write_durable_log(
      identity,
      earlier_events ++
        [
          "2026-10-07T21:13:21Z [event:emit] id=507 ticket.#{id}.pr.opened: PR #42 opened",
          "2026-10-07T21:13:22Z [event:emit] id=508 ticket.#{id}.branch.push: commit abc123"
        ]
    )

    log_root = Application.get_env(:aiur, :log_file) |> Path.dirname() |> Path.dirname()
    Application.put_env(:aiur, :log_file, Path.join([log_root, "rotated", "log", "aiur.log"]))
    EndpointStubs.scope(build_events_log_fun: &Wave0bEvents.log/2)

    {:ok, facts} = Wave0bEvents.read(%{id: id, running: %{tracker_identity: identity}}, [])
    {:ok, rows} = facts.log
    events = ConversationEvents.from_log(rows, id, %{})

    assert Enum.take(Enum.map(events, &{&1.id, &1.ev}), -2) == [{"ev:log:507", "pr"}, {"ev:log:508", "commit"}]
    assert Enum.any?(events, &(&1.id == "ev:log:506" and &1.ev == "prog"))
    refute Enum.any?(events, &(&1.sub == "run-only history"))
  end

  test "joinable durable history reports unreadable storage and treats an absent log as empty" do
    id = "#{System.unique_integer([:positive])}"
    identity = identity(id)
    ref = %{id: id, running: %{tracker_identity: identity}}

    assert {:ok, %{log: {:ok, []}}} = Wave0bEvents.read(ref, [])

    path = Paths.timeline_event_log_path(identity)
    File.mkdir_p!(path)
    assert {:ok, %{log: {:error, {:unavailable, :eisdir}}}} = Wave0bEvents.read(ref, [])
  end

  test "the pause reason comes from the running entry" do
    assert {:ok, %{pause: :operator_pause, identity: nil}} = Wave0bEvents.read(%{id: "12", running: %{pause_reason: :operator_pause}}, [])
  end
end
