defmodule Aiur.AgentControlCLITodoSupport do
  import ExUnit.Assertions
  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI

  def capture_todo(ids, opts) do
    parent = self()
    ref = make_ref()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {ref, :exit_code, AgentControlCLI.todo(ids, opts)}) end)
        send(parent, {ref, :stdout, stdout})
      end)

    assert_receive {^ref, :stdout, stdout}, 1000
    assert_receive {^ref, :exit_code, exit_code}, 1000
    {stdout, stderr, exit_code}
  end

  def todo_config do
    %{
      queue_label: "sym:todo",
      active_states: ["todo", "working", "rework"],
      active_labels: ["sym:todo", "sym:working", "sym:rework"],
      terminal_labels: ["sym:done", "sym:cancelled"]
    }
  end

  def todo_deps(issues, opts \\ []) do
    parent = self()
    active = Keyword.get(opts, :active, Map.values(issues))
    fetch_active_result = Keyword.get(opts, :fetch_active_result, {:ok, active})
    add_result = Keyword.get(opts, :add_result, fn _id, _label -> :ok end)
    remove_result = Keyword.get(opts, :remove_result, fn _id, _label -> :ok end)
    ensure_started_result = Keyword.get(opts, :ensure_started_result, :ok)

    %{
      ensure_started: fn -> ensure_started_result end,
      load_config: fn -> {:ok, Keyword.get(opts, :config, todo_config())} end,
      fetch_issue: fn id ->
        send(parent, {:todo_fetch_issue, id})

        case Map.fetch(issues, id) do
          {:ok, {:error, reason}} -> {:error, reason}
          {:ok, issue} -> {:ok, [issue]}
          :error -> {:ok, []}
        end
      end,
      fetch_active: fn states ->
        send(parent, {:todo_fetch_active, states})
        fetch_active_result
      end,
      add_label: fn id, label ->
        send(parent, {:todo_add_label, id, label})
        add_result.(id, label)
      end,
      remove_label: fn id, label ->
        send(parent, {:todo_remove_label, id, label})
        remove_result.(id, label)
      end,
      request_refresh: fn identifiers ->
        send(parent, {:todo_request_refresh, identifiers})
        Keyword.get(opts, :request_refresh_result, %{queued: true})
      end,
      now_ms: Keyword.get(opts, :now_ms, fn -> 0 end)
    }
  end

  def scripted_clock(readings) do
    {:ok, agent} = Agent.start_link(fn -> readings end)

    fn ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [head | rest] -> {head, rest}
      end)
    end
  end
end
