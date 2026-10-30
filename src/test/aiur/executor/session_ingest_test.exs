Code.require_file("../conversation/journal_support.exs", __DIR__)

defmodule Aiur.Executor.SessionIngestTest do
  use ExUnit.Case, async: false
  alias Aiur.Conversation.TestSupport
  alias Aiur.Executor.{HookPayload, Session, SessionIngest}

  setup context do
    context = TestSupport.setup(context)
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(context.root, "executor"))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :executor_state_dir, value)
        :error -> Application.delete_env(:aiur, :executor_state_dir)
      end
    end)

    start_supervised!({Session, instance_key: "hook-ingest"})
    timer = start_supervised!({Agent, fn -> 0 end})
    start_supervised!({SessionIngest, pubsub: context.pubsub, clock: fn -> Agent.get(timer, & &1) end})
    :ok = Phoenix.PubSub.subscribe(context.pubsub, SessionIngest.topic())
    Map.put(context, :timer, timer)
  end

  test "recording supervises ingest after the binding" do
    specs = Aiur.Application.child_specs(interactive_cli?: false, headless?: true, dashboard?: false, recording?: true)

    modules =
      Enum.map(specs, fn
        module when is_atom(module) -> module
        {module, _opts} -> module
        %{id: id} -> id
      end)

    assert SessionIngest in modules
    assert Enum.find_index(modules, &(&1 == Session)) < Enum.find_index(modules, &(&1 == SessionIngest))
  end

  test "unattached and malformed hooks are counted without binding or publication" do
    dispatch("SessionStart")
    assert SessionIngest.rejected_counts()[:not_attached] == 1
    assert Session.current() == :none
    assert {:ok, _} = Session.attach(%{harness: "claude"})
    SessionIngest.dispatch(%{}, "claude")
    assert SessionIngest.rejected_counts()[:invalid_payload] == 1
    refute_receive {:executor_hook, _event}, 0
  end

  test "binds, touches, rebinds compact in the same session and ends stopped" do
    assert {:ok, pending} = Session.attach(%{harness: "claude"})
    dispatch("SessionStart")
    SessionIngest.rejected_counts()
    assert {:ok, bound} = Session.current()
    assert bound.binding_id == pending.binding_id
    assert bound.provider_session_id == "one"
    assert bound.pid == "123"
    assert_receive {:executor_hook, %{event: "SessionStart", session_id: "one", observed_at: observed}}, 1000
    assert bound.last_hook_at == DateTime.to_iso8601(observed)

    dispatch("SessionStart", "one", %{"source" => "compact", "pid" => nil})
    SessionIngest.rejected_counts()
    assert {:ok, rebound} = Session.current()
    assert rebound.provider_session_id == "one"
    assert rebound.start_reason == "start"
    assert_receive {:executor_hook, %{session_id: "one", source: "compact"}}, 1000

    dispatch("PostToolUse", "one")
    SessionIngest.rejected_counts()
    assert_receive {:executor_hook, %{event: "PostToolUse"}}, 1000
    dispatch("SessionEnd", "one")
    SessionIngest.rejected_counts()
    assert {:ok, detached} = Session.current()
    assert detached.state == "detached"
    assert detached.end_reason == "stopped"
    assert_receive {:executor_hook, %{event: "SessionEnd"}}, 1000
    dispatch("Stop", "one")
    assert SessionIngest.rejected_counts()[:not_attached] == 1
    refute_receive {:executor_hook, _event}, 0
  end

  test "real Claude compact payload without pid and clear new-session payload with hook pid rebind safely", %{root: root} do
    assert {:ok, _} = Session.attach(%{harness: "claude"})
    initial = claude_fixture_payload(root, "session", "startup")
    SessionIngest.dispatch(initial, "claude")
    assert_receive {:executor_hook, %{session_id: "session"}}, 1000
    assert {:ok, bound} = Session.current()
    assert bound.provider_session_id == "session"

    compact = claude_fixture_payload(root, "session", "compact") |> Map.delete("pid")
    SessionIngest.dispatch(compact, "claude")
    assert_receive {:executor_hook, %{event: "SessionStart", session_id: "session", source: "compact"}}, 1000

    clear_end =
      Path.join([__DIR__, "../../fixtures/executor_hooks/claude/SessionEnd.json"])
      |> Path.expand()
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("reason", "clear")
      |> Map.put("pid", "123")

    SessionIngest.dispatch(clear_end, "claude")
    assert_receive {:executor_hook, %{event: "SessionEnd", reason: "clear"}}, 1000

    cleared = claude_fixture_payload(root, "session-new", "clear") |> Map.put("pid", "123")
    SessionIngest.dispatch(cleared, "claude")
    assert_receive {:executor_hook, %{event: "SessionStart", session_id: "session-new", source: "clear"}}, 1000
    assert {:ok, rebound} = Session.current()
    assert rebound.provider_session_id == "session-new"
    assert rebound.start_reason == "clear"

    foreign = claude_fixture_payload(root, "foreign", "clear") |> Map.put("pid", "different") |> Map.put("transcript_path", nil)
    SessionIngest.dispatch(foreign, "claude")
    SessionIngest.rejected_counts()
    assert SessionIngest.rejected_counts()[:foreign_session] == 1
    assert {:ok, current} = Session.current()
    assert current.provider_session_id == "session-new"
    refute_receive {:executor_hook, %{session_id: "foreign"}}, 0
  end

  test "nil and rejected hook paths retain the same session locator but never cross a rebind", %{root: root} do
    path = Path.join(root, ".claude/projects/p/one.jsonl")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}\n")
    {:ok, event} = HookPayload.normalize(Map.put(raw("SessionStart"), "transcript_path", path), "claude", home: root)
    assert {:ok, _} = Session.attach(%{harness: "claude"})
    SessionIngest.dispatch(event)
    SessionIngest.rejected_counts()
    assert {:ok, initial} = Session.current()
    assert initial.transcript_path == path

    for incoming <- [nil, path <> ".missing"] do
      dispatch("PostToolUse", "one", %{"transcript_path" => incoming})
      SessionIngest.rejected_counts()
      assert {:ok, current} = Session.current()
      assert current.transcript_path == path
      assert current.locator_hash == initial.locator_hash
    end

    dispatch("SessionStart", "one", %{"source" => "compact"})
    SessionIngest.rejected_counts()
    assert {:ok, rebound} = Session.current()
    assert rebound.provider_session_id == "one"
    assert rebound.transcript_path == path
    assert rebound.locator_hash == initial.locator_hash
  end

  test "first hook from an already resumed harness binds without an earlier process identity" do
    assert {:ok, pending} = Session.attach(%{harness: "claude"})
    dispatch("SessionStart", "resumed", %{"source" => "resume"})
    assert SessionIngest.rejected_counts() == %{}
    assert {:ok, bound} = Session.current()
    assert bound.binding_id == pending.binding_id
    assert bound.provider_session_id == "resumed"
    assert bound.pid == "123"
    assert_receive {:executor_hook, %{session_id: "resumed", source: "resume"}}, 1000
  end

  test "foreign session, process and harness never update or publish" do
    assert {:ok, _} = Session.attach(%{harness: "claude"})
    dispatch("SessionStart")
    SessionIngest.rejected_counts()
    assert_receive {:executor_hook, %{session_id: "one"}}, 1000
    assert {:ok, before} = Session.current()
    dispatch("Stop", "foreign")
    dispatch("SessionStart", "foreign", %{"source" => "clear", "pid" => "other"})
    {:ok, codex} = HookPayload.normalize(raw("Stop"), "codex")
    SessionIngest.dispatch(codex)
    counts = SessionIngest.rejected_counts()
    assert counts[:foreign_session] == 3
    assert {:ok, ^before} = Session.current()
    refute_receive {:executor_hook, _event}, 0
  end

  test "limits one binding to 50 events per second and accepts the next window", %{timer: timer} do
    assert {:ok, _} = Session.attach(%{harness: "claude"})
    for _ <- 1..51, do: dispatch("PostToolUse")
    assert SessionIngest.rejected_counts()[:rate_limited] == 1
    for _ <- 1..50, do: assert_receive({:executor_hook, %{event: "PostToolUse"}}, 1000)
    refute_receive {:executor_hook, _event}, 0
    Agent.update(timer, fn _ -> 1000 end)
    dispatch("Stop")
    SessionIngest.rejected_counts()
    assert_receive {:executor_hook, %{event: "Stop"}}, 1000
  end

  defp dispatch(event, id \\ "one", extra \\ %{}) do
    SessionIngest.dispatch(Map.merge(raw(event, id), extra), "claude")
  end

  defp raw(event, id \\ "one"), do: %{"hook_event_name" => event, "session_id" => id, "pid" => "123", "source" => "startup"}

  defp claude_fixture_payload(root, session_id, source) do
    transcript = Path.join([root, ".claude", "projects", "fixture", session_id <> ".jsonl"])
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, "{}\n")

    Path.join([__DIR__, "../../fixtures/executor_hooks/claude/SessionStart.json"])
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
    |> Map.merge(%{"session_id" => session_id, "source" => source, "transcript_path" => transcript})
  end
end
