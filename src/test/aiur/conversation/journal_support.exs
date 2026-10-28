defmodule Aiur.Conversation.TestSupport do
  alias Aiur.Conversation.{Ingest, Ref, Store}
  alias Aiur.TestSupport.Isolation

  defmodule StoreDouble do
    alias Aiur.Conversation.{Store, TestSupport}
    def prepare(dir, ref), do: intercept(:prepare, fn -> Store.prepare(dir, ref) end)
    def rebuild_head(dir), do: intercept(:rebuild, fn -> Store.rebuild_head(dir) end)
    def stream_entries(dir, from, to), do: Store.stream_entries(dir, from, to)
    def append_session_line(dir, line), do: intercept(:session, fn -> Store.append_session_line(dir, line) end)

    def append_entries(dir, state, entries) do
      result = intercept(:append, fn -> Store.append_entries(dir, state, entries) end, {dir, state, entries})
      owner = Application.fetch_env!(:aiur, :conversation_test_control) |> Agent.get(& &1.owner)
      if entries != [] and match?({:ok, _}, result), do: send(owner, {:journal_batch, length(entries)})
      result
    end

    defp intercept(operation, fun, args \\ nil) do
      agent = Application.fetch_env!(:aiur, :conversation_test_control)

      action =
        Agent.get_and_update(agent, fn state ->
          {action, remaining} =
            case Map.get(state, operation, []) do
              [] -> {:pass, []}
              [action | remaining] -> {action, remaining}
            end

          {action, Map.put(state, operation, remaining)}
        end)

      owner = Agent.get(agent, & &1.owner)

      case action do
        :pass ->
          fun.()

        {:error, reason} ->
          {:error, reason}

        :blocked ->
          send(owner, {:store_blocked, operation, self()})

          receive do
            :release_store -> fun.()
          end

        :uncertain ->
          fun.()
          {:error, :eio}

        :partial ->
          {dir, state, entries} = args
          Store.append_entries(dir, state, entries, file_ops: TestSupport.PartialFile)

        :ambiguous ->
          {dir, state, entries} = args
          Store.append_entries(dir, state, entries, file_ops: TestSupport.FailedSync)
      end
    end
  end

  defmodule PartialFile do
    def write(fd, bytes) do
      {newline, 1} = :binary.match(bytes, "\n")
      :ok = :file.write(fd, binary_part(bytes, 0, newline + 5))
      {:error, :enospc}
    end

    def sync(fd), do: :file.sync(fd)
  end

  defmodule FailedSync do
    def write(fd, bytes), do: :file.write(fd, bytes)
    def sync(_fd), do: {:error, :eio}
  end

  defmodule Alerts do
    def emit_system(name, opts) do
      owner = Application.fetch_env!(:aiur, :conversation_test_control) |> Agent.get(& &1.owner)
      send(owner, {:journal_alert, name, opts})
      :ok
    end
  end

  def setup(context) do
    root = Aiur.TestSupport.tmp_root!("conversation-journal")
    previous = Map.new([:conversation_state_dir, :conversation_journal, :conversation_test_control], &{&1, Application.fetch_env(:aiur, &1)})
    {:ok, control} = Agent.start_link(fn -> %{owner: self()} end)
    owner = self()
    Agent.update(control, &Map.put(&1, :owner, owner))
    Application.put_env(:aiur, :conversation_state_dir, root)
    Application.put_env(:aiur, :conversation_test_control, control)
    {pubsub, _topic} = Isolation.start_pubsub!(context)
    now = DateTime.utc_now()
    Agent.update(control, &Map.put(&1, :now, now))

    Application.put_env(:aiur, :conversation_journal,
      store: StoreDouble,
      pubsub: pubsub,
      alerts: Alerts,
      run_id: "run-one",
      clock: fn -> Agent.get(control, & &1.now) end,
      send_after: fn _pid, _message, _ms -> make_ref() end
    )

    ref = Ref.executor()
    # The app supplies the production registry and supervisor. No provider is wired yet.
    ExUnit.Callbacks.on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Aiur.Conversation.JournalSupervisor), is_pid(pid), do: DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, pid)

      Enum.each(previous, &restore_env/1)

      :persistent_term.erase({Ingest, :dropped, Ref.conversation_id(ref)})
      :persistent_term.erase({Aiur.Conversation.Journal, Ref.conversation_id(ref), :pending_gaps})
      Aiur.TestCleanup.rm_rf!(root)
    end)

    Map.merge(context, %{root: root, ref: ref, now: now, control: control, pubsub: pubsub, dir: Path.join(root, Ref.conversation_id(ref))})
  end

  defp restore_env({key, {:ok, value}}), do: Application.put_env(:aiur, key, value)
  defp restore_env({key, :error}), do: Application.delete_env(:aiur, key)

  def source(id \\ "session-one"), do: %{harness: "codex", role: :executor, provider_session_id: id, aiur_attempt_id: nil, transcript_source: %{kind: :file, locator_hash: nil}, start_reason: :start}
  def event(n), do: %{role: "assistant", msg_id: "message-#{n}", body: "message #{n}", timestamp: Application.fetch_env!(:aiur, :conversation_journal)[:clock].()}

  def flush(ref) do
    {:ok, pid} = Ingest.writer(ref)
    GenServer.call(pid, :flush, :infinity)
  end

  def rows(dir) do
    {:ok, stream} = Store.stream_entries(dir, 1, :infinity)
    Enum.to_list(stream)
  end

  def sessions(dir), do: dir |> Path.join("sessions.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  def actions(control, operation, actions), do: Agent.update(control, &Map.put(&1, operation, actions))

  def state(ref) do
    {:ok, pid} = Ingest.writer(ref)
    :sys.get_state(pid, :infinity)
  end

  def tick(ref) do
    {:ok, pid} = Ingest.writer(ref)
    state = :sys.get_state(pid, :infinity)
    {_timer, token} = state.timer
    send(pid, {:flush, token})
    :sys.get_state(pid, :infinity)
  end
end
