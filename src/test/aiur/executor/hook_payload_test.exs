defmodule Aiur.Executor.HookPayloadTest do
  use ExUnit.Case, async: false
  alias Aiur.Executor.{HookPayload, TranscriptPath}

  setup do
    root = Aiur.TestSupport.tmp_root!("executor-hook-payload")
    handler = "hook-payload-#{System.unique_integer([:positive])}"
    owner = self()
    :telemetry.attach(handler, [:aiur, :executor, :hook], fn _, measurements, metadata, _ -> send(owner, {:count, measurements, metadata}) end, nil)

    on_exit(fn ->
      :telemetry.detach(handler)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: root}
  end

  test "documented Claude and Codex fixtures retain fields and discard unknown keys" do
    fixtures = Path.wildcard("test/fixtures/executor_hooks/*/*.json")
    assert length(fixtures) == 24

    for fixture <- fixtures do
      harness = fixture |> Path.dirname() |> Path.basename()
      raw = fixture |> File.read!() |> Jason.decode!()
      assert {:ok, event} = HookPayload.normalize(raw, harness)
      assert event.harness == harness
      assert event.event == raw["hook_event_name"]
      assert event.session_id == raw["session_id"]

      for field <- ~w(cwd source turn_id agent_id agent_type last_assistant_message notification_type tool_name pid model permission_mode)a,
          do: assert(Map.fetch!(event, field) == raw[Atom.to_string(field)])

      assert event.stop_hook_active == raw["stop_hook_active"]
      assert event.transcript_path == nil
      assert event.agent_transcript_path == nil
      assert %DateTime{} = event.observed_at
      refute Map.has_key?(event, :unknown)
    end
  end

  test "requires explicit supported harness and bounded nonempty identity" do
    for raw <- [%{}, %{"session_id" => "", "hook_event_name" => "Stop"}, %{"session_id" => String.duplicate("x", 257), "hook_event_name" => "Stop"}, %{"session_id" => "s", "hook_event_name" => 1}],
        do: assert(HookPayload.normalize(raw, "claude") == {:error, :invalid_payload})

    for harness <- [nil, "other", ["claude"]], do: assert(HookPayload.normalize(raw(), harness) == {:error, :invalid_payload})
  end

  test "bounds optional fields in bytes without splitting unicode and preserves false" do
    assert {:ok, event} = HookPayload.normalize(Map.merge(raw(), %{"last_assistant_message" => String.duplicate("€", 2000), "cwd" => 123, "stop_hook_active" => false}), "codex")
    assert byte_size(event.last_assistant_message) == 4095
    assert String.valid?(event.last_assistant_message)
    assert event.cwd == nil
    assert event.stop_hook_active == false
  end

  test "accepts owned matching paths for both harnesses and validates agent identity", %{root: root} do
    for {harness, relative} <- [{"claude", ".claude/projects/p/session.jsonl"}, {"codex", ".codex/sessions/2026/rollout-date-session.jsonl"}] do
      path = make_file(root, relative)
      assert TranscriptPath.validate(path, harness, "session", home: root) == {:ok, path}
      agent_relative = if harness == "claude", do: ".claude/projects/p/session/subagents/agent-agent.jsonl", else: String.replace(relative, "session.jsonl", "agent.jsonl")
      agent = make_file(root, agent_relative)
      assert {:ok, event} = HookPayload.normalize(Map.merge(raw(), %{"transcript_path" => path, "agent_transcript_path" => agent, "agent_id" => "agent"}), harness, home: root)
      assert event.transcript_path == path
      assert event.agent_transcript_path == agent
    end
  end

  test "Claude subagent paths require the agent prefix and the parent session", %{root: root} do
    for relative <- [
          ".claude/projects/p/session/subagents/agent.jsonl",
          ".claude/projects/p/foreign/subagents/agent-agent.jsonl",
          ".claude/projects/p/session/other/agent-agent.jsonl",
          ".claude/projects/p/session/subagents/agent-foreign.jsonl"
        ] do
      path = make_file(root, relative)
      payload = Map.merge(raw(), %{"agent_id" => "agent", "agent_transcript_path" => path})
      assert {:ok, event} = HookPayload.normalize(payload, "claude", home: root)
      assert event.agent_transcript_path == nil
      assert_receive {:count, %{count: 1}, %{reason: :transcript_path_rejected, rejection: :session_mismatch}}, 1000
    end
  end

  test "drops outside root traversal missing directories and mismatched names with reasons", %{root: root} do
    wrong = make_file(root, ".claude/projects/p/other.jsonl")

    for {path, reason} <- [
          {make_file(root, "session.jsonl"), :outside_root},
          {root <> "/.claude/projects/../session.jsonl", :outside_root},
          {root <> "/.claude/projects/missing.jsonl", :not_regular},
          {Path.dirname(wrong), :not_regular},
          {wrong, :session_mismatch}
        ] do
      assert {:ok, event} = HookPayload.normalize(Map.put(raw(), "transcript_path", path), "claude", home: root)
      assert event.transcript_path == nil
      assert_receive {:count, %{count: 1}, %{reason: :transcript_path_rejected, rejection: ^reason}}, 1000
    end
  end

  test "rejects symlinked leaf and parent even when they target a matching owned file", %{root: root} do
    target = make_file(root, ".claude/projects/real/session.jsonl")
    leaf = root <> "/.claude/projects/real/link.jsonl"
    File.ln_s!(target, leaf)
    parent = root <> "/.claude/projects/alias"
    File.ln_s!(Path.dirname(target), parent)

    for path <- [leaf, parent <> "/session.jsonl"] do
      assert TranscriptPath.validate(path, "claude", Path.basename(path, ".jsonl"), home: root) == {:error, :not_regular}
    end
  end

  defp raw, do: %{"session_id" => "session", "hook_event_name" => "Stop"}

  defp make_file(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}\n")
    path
  end
end
