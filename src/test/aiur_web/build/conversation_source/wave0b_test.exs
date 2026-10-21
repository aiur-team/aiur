defmodule AiurWeb.Build.ConversationSource.Wave0bTest do
  use Aiur.TestSupport

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Build.ConversationSource
  alias AiurWeb.Build.ConversationSource.{Entries, Wave0b}

  setup do
    root = Aiur.TestSupport.tmp_root!("conversation-source")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/aiur", workspace_root: root)
    workspace = Path.join([root, "owner", "aiur", "7"])
    File.mkdir_p!(Path.join(workspace, "logs"))
    EndpointStubs.scope(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: []}} end)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    {:ok, root: root, workspace: workspace, ref: %{id: "7", identity: nil, closed?: true, row: %{model: "Codex", effort: "high"}}}
  end

  test "empty retained file differs from missing history and legacy logs", %{ref: ref, workspace: workspace} do
    assert {:ok, %{state: :not_retained, entries: []}} = Wave0b.tail(ref, nil, [])
    File.write!(Path.join(workspace, "logs/agent.ndjson"), "")
    assert {:ok, %{state: :ended, entries: [], more?: false}} = Wave0b.tail(ref, nil, [])
    File.rm!(Path.join(workspace, "logs/agent.ndjson"))
    File.write!(Path.join(workspace, "logs/agent.md"), "## 2026-10-21T10:00:00Z · agent_message\n\nhello legacy\n")
    assert {:ok, %{state: :ended, note: "legacy_log"}} = Wave0b.tail(ref, nil, [])
  end

  test "prepare caches snapshot so polling does not fetch it", %{ref: ref, workspace: workspace} do
    test_pid = self()

    EndpointStubs.scope(
      build_conversation_snapshot_fun: fn _, _ ->
        send(test_pid, :snapshot_read)
        {:ok, %{running: []}}
      end
    )

    File.write!(Path.join(workspace, "logs/agent.ndjson"), "")
    assert {:ok, prepared} = Wave0b.prepare(ref, [])
    assert_received :snapshot_read
    assert prepared.path == Path.join(workspace, "logs/agent.ndjson")
    assert {:ok, %{state: :ended}} = Wave0b.tail(prepared, nil, [])
    refute_received :snapshot_read
  end

  test "invalid ids and other repositories cannot read local history", %{ref: ref} do
    assert {:error, :invalid_id} = Wave0b.tail(%{ref | id: "../../x"}, nil, [])
    foreign = %{ref | identity: %{owner: "owner", repository: "other"}}
    assert {:ok, %{state: :unavailable, reason: :other_repository, entries: []}} = Wave0b.tail(foreign, nil, [])
  end

  test "workspace and log symlink escapes are refused", %{ref: ref, root: root, workspace: workspace} do
    outside = Aiur.TestSupport.tmp_root!("conversation-outside")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(outside) end)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "agent.ndjson"), "private")
    File.ln_s!(Path.join(outside, "agent.ndjson"), Path.join(workspace, "logs/agent.ndjson"))
    assert {:ok, %{state: :unavailable, reason: :workspace_symlink_escape, entries: []}} = Wave0b.tail(ref, nil, [])
    File.ln_s!(outside, Path.join([root, "owner", "aiur", "8"]))
    assert {:ok, %{state: :unavailable, reason: :workspace_symlink_escape}} = Wave0b.tail(%{ref | id: "8"}, nil, [])
  end

  test "snapshot failure preserves file entries without inventing ended state", %{ref: ref, workspace: workspace} do
    write_event(workspace, "agent_message", %{"last_message" => "hidden raw data"})
    EndpointStubs.scope(build_conversation_snapshot_fun: fn _, _ -> exit(:unavailable) end)
    assert {:ok, %{state: :unavailable, reason: :running_unknown, live?: false, entries: [entry]}} = Wave0b.tail(ref, nil, [])
    assert entry.k == "sys"
    assert entry.text == "Agent Message"
  end

  test "remote and missing local logs use projection windows and preserve state", %{ref: ref, workspace: workspace} do
    running = %{identifier: "7", issue_id: "node7", workspace_path: workspace, worker_host: "remote", live_conversation: %{generation_handle: "handle"}}

    EndpointStubs.scope(
      build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [running]}} end,
      build_conversation_resolve_fun: fn "handle" -> {:ok, %{state: :stale, messages: [%{id: "m1", role: "agent", body: "answer", occurred_at: "n/a"}], evicted_count: 12}} end
    )

    assert {:ok, %{state: :stale, live?: false, note: "remote_window", evicted: 12, entries: [%{id: "m1", k: "say", text: "answer", at: nil}]}} = Wave0b.tail(ref, nil, [])
    EndpointStubs.scope(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [%{running | worker_host: nil}]}} end)
    assert {:ok, %{state: :stale, note: "live_window", entries: [_]}} = Wave0b.tail(ref, nil, [])
  end

  test "unresolvable projection preserves local entries with unavailable state", %{ref: ref, workspace: workspace} do
    write_event(workspace, "agent_message", %{"last_message" => "private"})
    running = %{identifier: "7", issue_id: "node7", workspace_path: workspace, live_conversation: %{generation_handle: "handle"}}
    EndpointStubs.scope(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [running]}} end, build_conversation_resolve_fun: fn _ -> raise "boom" end)
    assert {:ok, %{state: :unavailable, entries: [_]}} = Wave0b.tail(ref, nil, [])
    EndpointStubs.scope(build_conversation_resolve_fun: fn _ -> exit(:gone) end)
    assert {:ok, %{state: :unavailable, entries: [_]}} = Wave0b.tail(ref, nil, [])
  end

  test "mapping hides prompts, raw data and command output while retaining design kinds" do
    rows = [
      %{id: "1", role: "assistant", title: "Agent", body: "hello", timestamp: "n/a"},
      %{id: "2", role: "user", title: "Executor", body: "go", timestamp: "2026-10-21T10:00:00Z", action_id: "action"},
      %{id: "3", role: "user", title: "Issue prompt", body: "SECRET_PROMPT"},
      %{id: "4", role: "user", title: "Issue prompt", body: "SECRET_PROMPT"},
      %{id: "5", role: "system", title: "Coordination event", body: "SECRET_JSON", action_id: "action"},
      %{id: "6", role: "tool", title: "Command failed", body: "$ first\nsecond\nexit 2\n\nTOKEN=abc"},
      %{id: "7", role: "tool", title: "Command output", body: "$ auth\nexit 0\n\ntoken is invalid"},
      %{id: "8", role: "alert", title: "attention", body: "SECRET_JSON"},
      %{id: "9", role: "system", title: "Warning", body: "warning line\nSECRET_JSON"},
      %{id: "10", role: "system", title: "Something", body: "SECRET_JSON"}
    ]

    mapped = Entries.map_entries(rows, %{model: "Codex", effort: "high"}, true)
    assert Enum.map(mapped, & &1.k) == ["say", "op", "sys", "sys", "sys", "tool", "tool", "sys", "sys", "sys"]

    assert Enum.map(mapped, &Map.get(&1, :text)) == [
             "hello",
             "go",
             "Picked up",
             "Picked up by Codex · high effort",
             "Coordination event",
             nil,
             nil,
             "Alert · attention",
             "Warning · warning line",
             "Something"
           ]

    assert Enum.at(mapped, 1).id == "answer:action"
    assert Enum.at(mapped, 1).cursor == "2"
    assert Enum.at(mapped, 4).id == "5"
    refute Map.has_key?(Enum.at(mapped, 4), :cursor)
    assert Enum.at(mapped, 1).at == DateTime.to_unix(~U[2026-10-21 10:00:00Z], :millisecond)
    assert hd(mapped).at == nil
    assert Enum.at(mapped, 5) == %{id: "6", at: nil, k: "tool", name: "bash", arg: "first …", res: "✗ exit 2", bad: true}
    assert Enum.at(mapped, 6).res == "✗ auth failure"
    encoded = Jason.encode!(mapped)
    refute encoded =~ "SECRET"
    refute encoded =~ "TOKEN=abc"
    refute encoded =~ "token is invalid"
  end

  test "pick-up uses the wire row agent display name and effort" do
    prompt = %{id: "pickup", role: "user", title: "Issue prompt", body: "secret"}
    row = %{"agent" => %{"model" => "codex", "name" => "GPT-6 Codex", "effort" => "high"}}
    assert [%{text: "Picked up by GPT-6 Codex · high effort"}] = Entries.map_entries([prompt], row, true)
    assert [%{text: "Picked up"}] = Entries.map_entries([prompt], row, false)
  end

  test "text is valid UTF-8 and bounded" do
    [entry] = Entries.map_entries([%{id: "x", role: "assistant", body: <<255>> <> String.duplicate("é", 8_100)}], %{}, true)
    assert String.valid?(entry.text)
    assert String.length(entry.text) == 8_000
    assert String.ends_with?(entry.text, "…")
  end

  test "local running states and subscriptions use the pinned handle", %{ref: ref, workspace: workspace} do
    running = %{identifier: "7", issue_id: "node7", workspace_path: workspace, live_conversation: %{generation_handle: "A"}}
    test_pid = self()

    EndpointStubs.scope(
      build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [running]}} end,
      build_conversation_subscribe_fun: fn handle ->
        send(test_pid, {:subscribed, handle})
        :ok
      end,
      build_conversation_unsubscribe_fun: fn handle ->
        send(test_pid, {:unsubscribed, handle})
        :ok
      end
    )

    assert {:ok, prepared} = Wave0b.prepare(ref, [])
    assert :ok = Wave0b.subscribe(prepared, [])
    assert_received {:subscribed, "A"}

    for state <- [:live, :known_empty, :ended, :stale, :restart_unknown] do
      EndpointStubs.scope(build_conversation_resolve_fun: fn "A" -> {:ok, %{state: state, messages: []}} end)
      assert {:ok, view} = Wave0b.tail(prepared, nil, [])
      assert view.state == state
      assert view.live? == state in [:live, :known_empty]
    end

    assert :ok = Wave0b.unsubscribe(prepared, [])
    assert_received {:unsubscribed, "A"}
  end

  test "retrying and idle entries do not manufacture a running session", %{ref: ref} do
    entry = %{identifier: "7", issue_id: "node7"}
    EndpointStubs.scope(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [], retrying: [entry], idle: []}} end)
    assert {:ok, %{state: :not_retained}} = Wave0b.tail(ref, nil, [])
    EndpointStubs.scope(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: [], retrying: [], idle: [entry]}} end)
    assert {:ok, %{state: :not_retained}} = Wave0b.tail(ref, nil, [])
  end

  defmodule Spy do
    def tail(ref, cursor, opts), do: {:ok, {ref, cursor, opts}}
    def subscribe(_, _), do: exit(:gone)
  end

  test "source seam appends opts, supports optional prepare and catches source exits" do
    assert {:ok, {%{id: "7"}, nil, [limit: 3]}} = ConversationSource.call({Spy, [limit: 3]}, :tail, [%{id: "7"}, nil])
    assert {:ok, %{id: "7"}} = ConversationSource.call(Spy, :prepare, [%{id: "7"}])
    assert {:error, :unavailable} = ConversationSource.call(Spy, :subscribe, [%{id: "7"}])
  end

  defp write_event(workspace, event, payload) do
    File.write!(Path.join(workspace, "logs/agent.ndjson"), Jason.encode!(%{timestamp: "2026-10-21T10:00:00Z", event: event, payload: payload}) <> "\n")
  end
end
