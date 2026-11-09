defmodule Aiur.ControlCLI.PendingCommands do
  @moduledoc """
  Executor Commands held until their blocker tickets merge (`aiur command request --after`).

  A pending Command lives only in this durable file, so it reaches no inbox until
  every blocker is closed as completed. A blocker closed as not planned (or as a
  duplicate) drops the Command and wakes the Executor with `executor.command.dropped`.
  """

  use GenServer
  require Logger

  alias Aiur.ControlCLI.ExecutorRequest
  alias Aiur.Executor.StatePaths
  alias Aiur.{ExecutorEvents, JsonStore, Tracker}

  @poll_ms 60_000
  # The tracker read may be served from cache; a minute of staleness only delays publication.
  @closure_max_age_ms 60_000
  @dropped_reasons ["not_planned", "duplicate"]
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

  @doc "Stores a validated request until its blockers merge."
  @spec defer(keyword(), [String.t()], GenServer.server()) :: {:ok, map()} | {:error, term()}
  def defer(params, blockers, server \\ __MODULE__) do
    stored = params |> Keyword.take(@param_keys) |> Keyword.put_new_lazy(:idempotency_key, fn -> "exec-#{Ecto.UUID.generate()}" end)
    # The same string-keyed shape in memory and after a restart.
    stored = stored |> Map.new() |> Jason.encode!() |> Jason.decode!()
    GenServer.call(server, {:defer, stored, blockers})
  catch
    :exit, _reason -> {:error, :daemon_unavailable}
  end

  @spec list(GenServer.server()) :: [map()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc false
  @spec poll(GenServer.server()) :: :ok
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, 60_000)

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &StatePaths.pending_commands_path/0)

    state = %{
      path: path,
      entries: load(path),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      closure_fun: Keyword.get(opts, :closure_fun, &Tracker.issue_closure(&1, @closure_max_age_ms)),
      publish_fun: Keyword.get(opts, :publish_fun, &publish(&1, Keyword.get(opts, :request_deps, []))),
      wake_fun: Keyword.get(opts, :wake_fun, &wake/3)
    }

    schedule(state.poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:defer, params, blockers}, _from, state) do
    entry = %{"id" => "pend_" <> String.slice(Ecto.UUID.generate(), 0, 8), "after" => blockers, "params" => params, "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()}
    entries = Map.put(state.entries, entry["id"], entry)
    persist(state.path, entries)
    {:reply, {:ok, entry}, %{state | entries: entries}}
  end

  def handle_call(:list, _from, state), do: {:reply, state.entries |> Map.values() |> Enum.sort_by(& &1["created_at"]), state}
  def handle_call(:poll, _from, state), do: {:reply, :ok, check(state)}

  @impl true
  def handle_info(:poll, state) do
    schedule(state.poll_ms)
    {:noreply, check(state)}
  end

  defp schedule(:infinity), do: :ok
  defp schedule(ms), do: Process.send_after(self(), :poll, ms)

  defp check(state) do
    entries = Enum.reduce(state.entries, state.entries, fn {id, entry}, acc -> if settle(entry, state), do: Map.delete(acc, id), else: acc end)
    if map_size(entries) != map_size(state.entries), do: persist(state.path, entries)
    %{state | entries: entries}
  end

  # Returns true once the entry has left the store, published or dropped.
  defp settle(entry, state) do
    case resolve(entry["after"], state.closure_fun) do
      :waiting ->
        false

      {:dropped, blocker, reason} ->
        state.wake_fun.(entry, blocker, reason)
        true

      :ready ->
        published?(entry, state)
    end
  end

  defp resolve(blockers, closure_fun) do
    closures = Enum.map(blockers, &{&1, closure_fun.(&1)})

    case Enum.find(closures, &match?({_id, {:ok, %{open?: false, state_reason: reason}}} when reason in @dropped_reasons, &1)) do
      {id, {:ok, %{state_reason: reason}}} -> {:dropped, id, reason}
      nil -> if Enum.all?(closures, &match?({_id, {:ok, %{open?: false}}}, &1)), do: :ready, else: :waiting
    end
  end

  # The stored idempotency key makes a retried publish return the same Command.
  defp published?(entry, state) do
    case state.publish_fun.(entry["params"]) do
      0 ->
        true

      64 ->
        state.wake_fun.(entry, nil, "refused")
        true

      _transient ->
        false
    end
  end

  defp publish(params, deps) do
    params = Enum.flat_map(@param_keys, fn key -> if Map.has_key?(params, Atom.to_string(key)), do: [{key, params[Atom.to_string(key)]}], else: [] end)
    deps = Keyword.merge([result_fun: fn _decision, _status, _source, _json -> :ok end, error_fun: &Logger.warning/1], deps)
    ExecutorRequest.request(params, deps)
  end

  defp wake(entry, blocker, reason) do
    params = entry["params"]
    payload = %{pending_id: entry["id"], blocker: blocker, reason: reason, after: entry["after"], question: params["question"], short_summary: params["short_summary"]}

    case ExecutorEvents.publish("executor.command.dropped", payload, source: :internal) do
      {:ok, _id, _delivered} -> :ok
      {:error, error} -> Logger.error("pending Command #{entry["id"]} dropped (#{reason}) but the Executor wake failed: #{inspect(error)}")
    end
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
