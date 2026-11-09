defmodule Aiur.ControlCLI.PendingCommands do
  @moduledoc """
  Executor Commands held until their blocker tickets merge (`aiur command request --after`).

  A pending Command lives only in this durable file, so it reaches no inbox until
  every blocker is closed as `completed`. Any other closure (`not_planned`,
  `duplicate`, no reason, another reason) or a deleted ticket drops it and raises
  a `ticket.<blocker>.agent.attention.command_dropped` attention for the Executor.

  There is no polling timer. A blocker is read once when the request is made, once
  when the daemon sees that ticket's PR merge or its agent state move to done or
  cancelled, and once at daemon start for blockers still open.
  """

  use GenServer
  require Logger

  alias Aiur.ControlCLI.ExecutorRequest
  alias Aiur.Events.Exchange
  alias Aiur.Executor.StatePaths
  alias Aiur.{JsonStore, Signal, Tracker}

  # One cached minute keeps a burst of events for one ticket to one GitHub read.
  @closure_max_age_ms 60_000
  @caller "pending_commands"
  # Retries a failed publish or attention; it never reads the tracker.
  @retry_ms 60_000
  @triggers ["ticket.*.pr.merged", "ticket.*.issue.label.added.agent.done", "ticket.*.issue.label.added.agent.cancelled", "ticket.*.issue.label.added.agent.canceled"]
  @ticket ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @param_keys ~w(question options media recommend blocking urgency ticket long_context_markdown short_summary executor_id idempotency_key)a

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Parses `--after 5,#6` into blocker identifiers."
  @spec parse_after(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def parse_after(raw) when is_binary(raw) do
    ids = raw |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("#"))) |> Enum.uniq()
    if ids != [] and Enum.all?(ids, &Regex.match?(@ticket, &1)), do: {:ok, ids}, else: {:error, "--after expects ticket[,ticket...]"}
  end

  @doc "Checks every blocker exists and is not closed unmerged, then stores the request."
  @spec defer(keyword(), [String.t()], GenServer.server()) :: {:ok, map()} | {:error, term()}
  def defer(params, blockers, server \\ __MODULE__) do
    stored = params |> Keyword.take(@param_keys) |> Keyword.put_new_lazy(:idempotency_key, fn -> "exec-#{Ecto.UUID.generate()}" end)
    # The same string-keyed shape in memory and after a restart.
    stored = stored |> Map.new() |> Jason.encode!() |> Jason.decode!()
    GenServer.call(server, {:defer, stored, blockers}, 60_000)
  catch
    :exit, _reason -> {:error, :daemon_unavailable}
  end

  @spec list(GenServer.server()) :: [map()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "Removes a pending Command before it publishes."
  @spec cancel(String.t(), GenServer.server()) :: {:ok, map()} | {:error, :not_found | :daemon_unavailable}
  def cancel(id, server \\ __MODULE__) do
    GenServer.call(server, {:cancel, id})
  catch
    :exit, _reason -> {:error, :daemon_unavailable}
  end

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &StatePaths.pending_commands_path/0)
    Keyword.get(opts, :subscribe_fun, &subscribe/0).()

    state = %{
      path: path,
      entries: load(path),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      retry_ref: nil,
      closure_fun: Keyword.get(opts, :closure_fun, &Tracker.issue_closure(&1, @closure_max_age_ms, @caller)),
      publish_fun: Keyword.get(opts, :publish_fun, &publish(&1, Keyword.get(opts, :request_deps, []))),
      wake_fun: Keyword.get(opts, :wake_fun, &wake/3)
    }

    {:ok, state, {:continue, :catch_up}}
  end

  @impl true
  def handle_continue(:catch_up, state) do
    blockers = state.entries |> Map.values() |> Enum.flat_map(&waiting_on/1) |> Enum.uniq()
    {:noreply, Enum.reduce(blockers, state, &observe(&2, &1)) |> settle()}
  end

  @impl true
  def handle_call({:defer, params, blockers}, _from, state) do
    observations = Enum.map(blockers, &{&1, classify(state.closure_fun.(&1))})

    case Enum.find(observations, fn {_id, observation} -> not match?({:closed, _}, observation) and observation != :open end) do
      nil ->
        closed = for {id, {:closed, reason}} <- observations, into: %{}, do: {id, reason}
        entry = %{"id" => "pend_" <> String.slice(Ecto.UUID.generate(), 0, 8), "after" => blockers, "params" => params, "closed" => closed, "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()}
        entries = Map.put(state.entries, entry["id"], entry)
        persist(state.path, entries)
        state = settle(%{state | entries: entries})
        {:reply, {:ok, Map.put(entry, "status", if(Map.has_key?(state.entries, entry["id"]), do: "pending", else: "published"))}, state}

      {id, observation} ->
        {:reply, {:error, refusal(id, observation)}, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, state.entries |> Map.values() |> Enum.sort_by(& &1["created_at"]), state}

  def handle_call({:cancel, id}, _from, state) do
    case Map.pop(state.entries, id) do
      {nil, _entries} ->
        {:reply, {:error, :not_found}, state}

      {entry, entries} ->
        persist(state.path, entries)
        {:reply, {:ok, entry}, %{state | entries: entries}}
    end
  end

  @impl true
  def handle_info({:event, event}, state) do
    with topic when is_binary(topic) <- event[:topic] || event["topic"],
         ["ticket", ticket | _rest] <- String.split(topic, "."),
         true <- Enum.any?(Map.values(state.entries), &(ticket in waiting_on(&1))) do
      {:noreply, state |> observe(ticket) |> settle()}
    else
      _ignored -> {:noreply, state}
    end
  end

  def handle_info(:retry, state), do: {:noreply, settle(%{state | retry_ref: nil})}

  defp subscribe, do: Enum.each(@triggers, &Exchange.subscribe/1)

  defp waiting_on(%{"dropped" => _}), do: []
  defp waiting_on(entry), do: entry["after"] -- Map.keys(entry["closed"] || %{})

  # One read per blocker, applied to every entry waiting on it.
  defp observe(state, blocker) do
    case classify(state.closure_fun.(blocker)) do
      {:closed, reason} -> update_waiting(state, blocker, &Map.update(&1, "closed", %{blocker => reason}, fn closed -> Map.put(closed, blocker, reason) end))
      {:dropped, reason} -> update_waiting(state, blocker, &Map.put(&1, "dropped", %{"blocker" => blocker, "reason" => reason}))
      _open_or_unknown -> state
    end
  end

  defp update_waiting(state, blocker, fun) do
    entries = Map.new(state.entries, fn {id, entry} -> {id, if(blocker in waiting_on(entry), do: fun.(entry), else: entry)} end)
    persist(state.path, entries)
    %{state | entries: entries}
  end

  # Merged means closed as completed. Every other closure, or a deleted ticket, drops the Command.
  defp classify({:ok, %{open?: true}}), do: :open
  defp classify({:ok, %{open?: false, state_reason: "completed"}}), do: {:closed, "completed"}
  defp classify({:ok, %{open?: false, state_reason: reason}}), do: {:dropped, reason || "closed_without_reason"}
  defp classify({:error, :not_found}), do: {:dropped, "not_found"}
  defp classify({:error, :unsupported}), do: :unsupported
  defp classify(other), do: {:unknown, other}

  defp refusal(_id, :unsupported), do: "the configured tracker cannot report ticket closure, so --after is unavailable"
  defp refusal(id, {:dropped, "not_found"}), do: "ticket #{id} was not found"
  defp refusal(id, {:dropped, reason}), do: "ticket #{id} is already closed without merging (#{reason})"
  defp refusal(id, {:unknown, reason}), do: "cannot read ticket #{id}: #{inspect(reason)}"

  defp settle(state) do
    {entries, retry?} = Enum.reduce(state.entries, {state.entries, false}, &settle_entry(&1, &2, state))
    if map_size(entries) != map_size(state.entries), do: persist(state.path, entries)
    schedule_retry(%{state | entries: entries}, retry?)
  end

  defp settle_entry({id, %{"dropped" => %{"blocker" => blocker, "reason" => reason}} = entry}, {entries, retry?}, state),
    do: finish(state.wake_fun.(entry, blocker, reason), id, entries, retry?)

  defp settle_entry({id, entry}, {entries, retry?}, state) do
    if waiting_on(entry) == [] do
      case state.publish_fun.(entry["params"]) do
        0 -> {Map.delete(entries, id), retry?}
        # The daemon refused the stored request; nothing a retry can fix.
        64 -> finish(state.wake_fun.(entry, hd(entry["after"]), "refused"), id, entries, retry?)
        _transient -> {entries, true}
      end
    else
      {entries, retry?}
    end
  end

  # The entry leaves the store only once the Executor has been told.
  defp finish(:ok, id, entries, retry?), do: {Map.delete(entries, id), retry?}
  defp finish(_failed, _id, entries, _retry?), do: {entries, true}

  defp schedule_retry(%{retry_ref: nil} = state, true), do: %{state | retry_ref: Process.send_after(self(), :retry, state.retry_ms)}
  defp schedule_retry(state, _retry?), do: state

  # The stored idempotency key makes a retried publish return the same Command.
  defp publish(params, deps) do
    params = Enum.flat_map(@param_keys, fn key -> if Map.has_key?(params, Atom.to_string(key)), do: [{key, params[Atom.to_string(key)]}], else: [] end)
    deps = Keyword.merge([result_fun: fn _decision, _status, _source, _json -> :ok end, error_fun: &Logger.warning/1], deps)
    ExecutorRequest.request(params, deps)
  end

  defp wake(entry, blocker, reason) do
    title = entry["params"]["short_summary"] || entry["params"]["question"]

    Signal.alert("ticket.#{blocker}.agent.attention.command_dropped",
      message: "Pending Command #{entry["id"]} dropped: ticket #{blocker} #{reason}",
      reason: "#{title} (after #{Enum.map_join(entry["after"], ", ", &"##{&1}")}) will not be published",
      needs_attention: true,
      durable: true
    )
  end

  defp load(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{} = entries} ->
        entries

      other ->
        # Keep the unreadable file for inspection instead of overwriting it on the next write.
        Logger.error("pending Commands store #{path} unreadable (#{inspect(other)}); moved aside")
        File.rename(path, path <> ".corrupt")
        %{}
    end
  end

  defp persist(path, entries), do: JsonStore.write!(path, entries)
end
