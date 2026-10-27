defmodule Aiur.BuildOrder.History.LabelBackfill do
  @moduledoc "Opt-in, durable rolling-hour pacing of confirmed historical classification labels."
  use GenServer
  alias Aiur.BuildOrder.History.LabelBackfill.{Checkpoint, Rules, Sources, Writer}
  alias Aiur.Config.Paths
  alias Aiur.GitHub.Access

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec plan(keyword()) :: map() | {:error, term()}
  def plan(opts \\ []), do: call({:plan, opts}, opts)
  @spec start(keyword()) :: map() | {:error, term()}
  def start(opts), do: call({:start, opts}, opts)
  @spec pause(keyword()) :: map() | {:error, term()}
  def pause(opts \\ []), do: call(:pause, opts)
  @spec resume(keyword()) :: map() | {:error, term()}
  def resume(opts \\ []), do: call(:resume, opts)
  @spec status(keyword()) :: map() | {:error, term()}
  def status(opts \\ []), do: call(:status, opts)
  @spec tick(keyword()) :: map() | {:error, term()}
  def tick(opts \\ []), do: call(:tick, opts)

  defp call(message, opts) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), message, 60_000)
  catch
    :exit, _ -> {:error, :label_writes_unavailable}
  end

  @impl true
  def init(opts) do
    repo = Keyword.get_lazy(opts, :repository, &Aiur.Tracker.project_identity/0)
    path = Keyword.get_lazy(opts, :state_path, &state_path/0)

    {data, unavailable} =
      case Checkpoint.load(path, repo) do
        {:ok, data} -> {data, nil}
        {:error, reason} -> {Checkpoint.empty(repo), reason}
      end

    state = %{
      data: data,
      unavailable: unavailable,
      path: path,
      opts: opts,
      readers: Sources.readers(opts),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      tracker: Keyword.get(opts, :tracker, Aiur.Tracker),
      core_limit: Keyword.get_lazy(opts, :agent_core_limit, fn -> Access.guard_settings().agent_core_limit_per_hour end),
      batch: nil,
      tick_ms: Keyword.get(opts, :tick_ms, 60_000)
    }

    schedule(state)
    if data.run.state == :running, do: send(self(), :work)
    {:ok, state}
  end

  defp state_path do
    case Paths.build_history_state_dir() do
      {:ok, dir} -> Path.join(dir, "history-label-writes.json")
      _ -> nil
    end
  end

  @impl true
  def handle_call(_message, _from, %{unavailable: reason} = state) when not is_nil(reason), do: {:reply, {:error, reason}, state}
  def handle_call({:plan, opts}, _from, state), do: {:reply, Sources.plan(state.readers, opts), state}
  def handle_call(:status, _from, state), do: {:reply, status_value(state), state}

  def handle_call({:start, opts}, _from, state) do
    plan = Sources.plan(state.readers, opts)
    per_hour = Keyword.get(opts, :per_hour, 60)
    maximum = Rules.max_per_hour(state.core_limit)

    case validate_start(state, plan, opts, per_hour, maximum) do
      :ok -> start_run(state, plan, opts, per_hour)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:pause, _from, state), do: transition(state, :paused)

  def handle_call(:resume, _from, state) do
    cond do
      agent_workspace?(state) -> {:reply, {:error, :agent_workspace_refused}, state}
      state.data.run.state not in [:paused, :stopped] -> {:reply, {:error, :not_paused}, state}
      true -> transition(state, :running)
    end
  end

  def handle_call(:tick, from, state), do: {:noreply, begin_tick(state, from)}

  defp validate_start(state, plan, opts, per_hour, maximum) do
    cond do
      agent_workspace?(state) -> {:error, :agent_workspace_refused}
      state.data.run.state in [:running, :paused, :stopped] -> {:error, :use_resume}
      not is_integer(per_hour) or per_hour < 1 or per_hour > maximum -> {:error, {:maximum, maximum}}
      true -> validate_plan(plan, opts)
    end
  end

  defp validate_plan(plan, opts) do
    cond do
      not is_integer(opts[:expect]) or opts[:expect] < 0 -> {:error, :expect_required}
      plan.tracker == :unsupported -> {:error, :unsupported}
      plan.total == :unknown -> {:error, {:plan_unknown, plan.unknown}}
      plan.total > opts[:expect] -> {:error, {:expect_exceeded, plan.total}}
      true -> :ok
    end
  end

  defp agent_workspace?(state), do: Keyword.get(state.opts, :agent_workspace, System.get_env("AIUR_AGENT_WORKSPACE", "")) != ""

  defp start_run(state, plan, opts, per_hour) do
    items =
      plan.items
      |> Enum.filter(&(&1.decision in [:write, {:done, :already_present}]))
      |> Map.new(fn item ->
        kept = Map.take(item, [:ticket, :kind, :label, :slug_or_epic])
        {key(item), Map.merge(kept, %{status: :pending, attempts: 0, at: nil, seen_at: nil})}
      end)

    run = %{
      state: :running,
      per_hour: per_hour,
      epic_labels: Keyword.get(opts, :epic_labels, false),
      started_by: "cli:" <> System.get_env("USER", "operator"),
      started_at: state.clock.(),
      expect: opts[:expect],
      hold_until: nil,
      stop_reason: nil
    }

    # Retain previous request reservations even when starting another completed run.
    next = persist(%{state | data: %{state.data | run: run, items: items, ensured: []}})
    if is_nil(next.unavailable), do: send(self(), :work)
    {:reply, result(next), next}
  end

  defp transition(state, target) do
    next = update_run(state, %{state: target, stop_reason: nil}) |> persist()
    if target == :running and is_nil(next.unavailable), do: send(self(), :work)
    {:reply, result(next), next}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule(state)
    send(self(), :work)
    {:noreply, state}
  end

  def handle_info(:work, state), do: {:noreply, begin_tick(state, nil)}

  def handle_info(:next, %{batch: %{ids: []} = batch} = state) do
    next = finish(state)
    Enum.each(batch.waiters, &GenServer.reply(&1, status_value(next)))
    {:noreply, %{next | batch: nil}}
  end

  def handle_info(:next, %{batch: %{ids: [id | rest]} = batch} = state) do
    next = process_one(id, state)
    # Yield after label creation so a queued pause can prevent the label request.
    ensured? = next.data.ensured != state.data.ensured
    ids = if ensured?, do: [id | rest], else: rest
    send(self(), :next)
    {:noreply, %{next | batch: %{batch | ids: ids}}}
  end

  defp begin_tick(%{batch: nil} = state, from) do
    ids = state.data.items |> Enum.sort_by(fn {_, item} -> {item.ticket, item.label} end) |> Enum.map(&elem(&1, 0))
    send(self(), :next)
    %{state | batch: %{ids: ids, waiters: List.wrap(from)}}
  end

  defp begin_tick(state, nil), do: state
  defp begin_tick(state, from), do: %{state | batch: %{state.batch | waiters: [from | state.batch.waiters]}}

  defp schedule(state), do: Process.send_after(self(), :tick, state.tick_ms)
  defp result(%{unavailable: nil} = state), do: status_value(state)
  defp result(state), do: {:error, state.unavailable}

  defp key(item), do: "#{item.ticket}/#{item.label}"
  defp process_one(id, state), do: Writer.process_one(id, state)
  defp finish(state), do: Writer.finish(state)
  defp persist(state), do: Writer.persist(state)
  defp status_value(state), do: Writer.status(state)
  defp update_run(state, fields), do: Writer.update_run(state, fields)
end
