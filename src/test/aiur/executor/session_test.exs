Code.require_file("../conversation/journal_support.exs", __DIR__)

defmodule Aiur.Executor.SessionTest do
  use ExUnit.Case, async: false
  alias Aiur.Conversation.Ingest
  alias Aiur.Executor.{Session, SessionRecord}
  import Aiur.Conversation.TestSupport

  setup context do
    context = Aiur.Conversation.TestSupport.setup(context)
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(context.root, "executor"))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :executor_state_dir, value)
        :error -> Application.delete_env(:aiur, :executor_state_dir)
      end
    end)

    clock = fn -> Agent.get(context.control, & &1.now) end
    start_supervised!({Session, instance_key: "instance-one", clock: clock})
    Map.put(context, :clock, clock)
  end

  test "recording supervises the binding after the journal infrastructure" do
    specs = Aiur.Application.child_specs(interactive_cli?: false, headless?: true, dashboard?: false, recording?: true)

    modules =
      Enum.map(specs, fn
        module when is_atom(module) -> module
        {module, _opts} -> module
        %{id: id} -> id
      end)

    index = fn module -> Enum.find_index(modules, &(&1 == module)) end
    assert Session in modules
    assert index.(Aiur.Conversation.JournalSupervisor) < index.(Session)
    assert index.(Aiur.Events.Exchange) < index.(Session)
  end

  test "opt-in reserves pending and live bindings and names the owner" do
    assert Session.current() == :none
    assert {:ok, pending} = Session.attach(%{harness: "claude", consumer_id: "owner"})
    assert pending.state == "awaiting_first_hook"
    assert pending.generation == 1
    assert {:error, {:already_attached, owner}} = Session.attach(%{harness: "codex"})
    assert owner.binding_id == pending.binding_id
    assert {:ok, bound} = Session.bind_provider_session(pending.binding_id, hook())
    assert {:error, {:already_attached, owner}} = Session.attach(%{harness: "codex"})
    assert owner.binding_id == bound.binding_id
    assert owner.harness == "claude"
    assert owner.last_hook_at == bound.last_hook_at
    refute Map.has_key?(owner, :transcript_path)
  end

  test "takeover ends the old journal session superseded and fences old hooks", %{ref: ref, dir: dir} do
    binding = bound()
    append(binding, ref)
    assert {:ok, replacement} = Session.attach(%{harness: "codex", takeover?: true})
    assert replacement.generation == binding.generation + 1
    assert replacement.binding_id != binding.binding_id
    assert replacement.takeover_armed
    assert :ok = flush(ref)
    assert Enum.any?(sessions(dir), &(&1["type"] == "end" and &1["end_reason"] == "superseded"))
    assert {:error, :not_attached} = Session.bind_provider_session(binding.binding_id, hook())
    assert {:ok, new} = Session.bind_provider_session(replacement.binding_id, hook("new"))
    refute new.takeover_armed
    assert new.provider_session_id == "new"
    assert {:error, :foreign_session} = Session.bind_provider_session(new.binding_id, hook("third"))
  end

  test "foreign hooks and invalid inputs never mutate the binding and are counted" do
    binding = bound()
    assert {:error, :foreign_session} = Session.bind_provider_session(binding.binding_id, hook("foreign"))
    assert {:error, :foreign_session} = Session.bind_provider_session(binding.binding_id, Map.put(hook(), :pid, "other"))
    assert {:error, :foreign_session} = Session.rebind_on_session_start(binding.binding_id, Map.merge(hook("two"), %{pid: "other", source: "clear"}))
    assert {:error, :invalid_hook} = Session.bind_provider_session(binding.binding_id, %{session_id: ""})
    assert {:error, :invalid_hook} = Session.bind_provider_session(binding.binding_id, %{session_id: "one", transcript_path: 9})
    assert {:error, :invalid_harness} = Session.attach(%{harness: "other"})
    assert {:error, :invalid_consumer_id} = Session.attach(%{harness: "claude", consumer_id: 1})
    assert {:error, :invalid_request} = Session.record_offset(binding.binding_id, -1)
    assert Session.rejected_counts()[:foreign_session] == 3
    assert {:ok, ^binding} = Session.current()
  end

  test "SessionStart clear requires the same Claude process and carries the new start reason", %{ref: ref, dir: dir} do
    binding = bound()
    append(binding, ref)
    assert {:ok, _} = Session.record_offset(binding.binding_id, 123)
    assert {:error, :foreign_session} = Session.rebind_on_session_start(binding.binding_id, Map.merge(hook("two"), %{source: "clear", pid: "other"}))
    assert {:error, :foreign_session} = Session.rebind_on_session_start(binding.binding_id, Map.put(hook("two"), :source, "startup"))
    assert {:ok, next} = Session.rebind_on_session_start(binding.binding_id, Map.put(hook("two"), :source, "clear"))
    assert next.provider_session_id == "two"
    assert next.start_reason == "clear"
    assert next.transcript_offset == 0
    append(next, ref)
    assert Enum.any?(sessions(dir), &(&1["type"] == "start" and &1["provider_session_id"] == "two" and &1["start_reason"] == "clear"))
    assert Enum.any?(sessions(dir), &(&1["type"] == "end" and &1["end_reason"] == "clear"))
  end

  test "restart restores binding identity offset and private mode", %{clock: clock} do
    binding = bound()
    assert {:ok, saved} = Session.record_offset(binding.binding_id, 99)
    path = SessionRecord.path("instance-one")
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    restart(clock)
    assert {:ok, ^saved} = Session.current()
    assert {:ok, detached} = Session.detach(saved.binding_id, :detached)
    restart(clock)
    assert {:ok, ^detached} = Session.current()
    assert {:ok, next} = Session.attach(%{harness: "claude"})
    assert next.generation == saved.generation + 1
  end

  test "public projection removes server paths but keeps the locator hash" do
    binding = bound()
    public = Session.public(binding)
    refute Map.has_key?(public, :transcript_path)
    refute Map.has_key?(public, :cwd)
    refute Map.has_key?(public, :pid)
    assert public.locator_hash == Base.encode16(:crypto.hash(:sha256, "/private/transcript.jsonl"), case: :lower)
    assert public.binding_id == binding.binding_id
  end

  test "TTL expires without rewriting current and new attach infers detached", %{control: control, ref: ref, dir: dir} do
    binding = bound()
    append(binding, ref)
    path = SessionRecord.path("instance-one")
    original = File.read!(path)
    Agent.update(control, &Map.update!(&1, :now, fn now -> DateTime.add(now, 600_001, :millisecond) end))
    assert {:ok, stale} = Session.current()
    refute stale.live?
    assert File.read!(path) == original
    assert {:ok, fresh} = Session.attach(%{harness: "claude"})
    assert fresh.generation == binding.generation + 1
    assert :ok = flush(ref)
    assert Enum.any?(sessions(dir), &(&1["type"] == "end" and &1["end_reason"] == "detached"))
  end

  test "a session arriving after TTL ends the stale provider before accepting another", %{control: control, ref: ref, dir: dir} do
    binding = bound()
    append(binding, ref)
    Agent.update(control, &Map.update!(&1, :now, fn now -> DateTime.add(now, 600_001, :millisecond) end))
    assert {:ok, next} = Session.bind_provider_session(binding.binding_id, hook("new"))
    assert next.live?
    assert next.provider_session_id == "new"
    assert :ok = flush(ref)
    assert Enum.any?(sessions(dir), &(&1["end_reason"] == "detached"))
  end

  test "touch coalesces file writes and eventually persists the last hook", %{now: now} do
    binding = bound()
    path = SessionRecord.path("instance-one")
    original = File.read!(path)
    at = DateTime.add(now, 500, :millisecond)
    assert {:ok, touched} = Session.touch(binding.binding_id, at)
    assert touched.last_hook_at == DateTime.to_iso8601(at)
    assert File.read!(path) == original
    at = DateTime.add(at, 100, :millisecond)
    assert {:ok, touched} = Session.touch(binding.binding_id, at)
    {timer, token} = :sys.get_state(Session).timer
    assert is_integer(Process.read_timer(timer))
    assert Process.read_timer(timer) <= 1000
    send(Process.whereis(Session), {:persist_touch, token})
    assert {:ok, ^touched} = Session.current()
    assert Jason.decode!(File.read!(path))["last_hook_at"] == DateTime.to_iso8601(at)
    assert {:ok, _} = Session.touch(binding.binding_id, DateTime.add(at, 1, :millisecond))
    {timer, token} = :sys.get_state(Session).timer
    assert {:ok, saved} = Session.record_offset(binding.binding_id, 100)
    assert Process.read_timer(timer) == false
    send(Process.whereis(Session), {:persist_touch, token})
    assert {:ok, ^saved} = Session.current()
    assert :sys.get_state(Session).timer == nil
  end

  test "detach ends the journal and rejects late hooks", %{ref: ref, dir: dir} do
    binding = bound()
    append(binding, ref)
    assert {:ok, detached} = Session.detach(binding.binding_id, "operator")
    assert detached.state == "detached"
    assert detached.end_reason == "operator"
    refute detached.live?
    assert {:error, :not_attached} = Session.bind_provider_session(binding.binding_id, hook())
    assert {:error, :not_attached} = Session.touch(binding.binding_id, DateTime.utc_now())
    assert Session.rejected_counts()[:not_attached] == 2
    assert :ok = flush(ref)
    assert Enum.any?(sessions(dir), &(&1["end_reason"] == "operator"))
  end

  test "empty instance refuses attach and distinct instance files do not cross-talk", %{clock: clock} do
    binding = bound()
    restart(clock, "")
    assert Session.current() == :none
    assert {:error, :missing_instance_key} = Session.attach(%{harness: "claude"})
    restart(clock, "instance-two")
    assert Session.current() == :none
    assert {:ok, second} = Session.attach(%{harness: "codex"})
    assert second.binding_id != binding.binding_id
    restart(clock)
    assert {:ok, ^binding} = Session.current()
  end

  test "corrupt JSON and invalid records are preserved and ignored", %{clock: clock} do
    binding = bound()
    path = SessionRecord.path("instance-one")

    for contents <- ["broken", "{\"v\":999}"] do
      stop_supervised!(Session)
      File.write!(path, contents)
      start_supervised!({Session, instance_key: "instance-one", clock: clock})
      assert Session.current() == :none
      assert Enum.any?(Path.wildcard(path <> ".corrupt-*"), &(File.read!(&1) == contents))
      assert {:ok, new} = Session.attach(%{harness: "claude"})
      assert new.binding_id != binding.binding_id
    end
  end

  defp hook(id \\ "one"), do: %{session_id: id, transcript_path: "/private/transcript.jsonl", cwd: "/private", pid: "123"}

  defp bound do
    {:ok, binding} = Session.attach(%{harness: "claude"})
    {:ok, binding} = Session.bind_provider_session(binding.binding_id, hook())
    binding
  end

  defp restart(clock, key \\ "instance-one") do
    stop_supervised!(Session)
    start_supervised!({Session, instance_key: key, clock: clock})
  end

  defp append(binding, ref) do
    source = %{source(binding.provider_session_id) | harness: binding.harness, start_reason: binding.start_reason}
    Ingest.append(ref, source, [event(binding.provider_session_id)])
    assert :ok = flush(ref)
  end
end
