defmodule Aiur.Orchestrator.OptimisticLedger do
  @moduledoc "Durable optimistic dispatch attempts; writes are serialized, reads use ETS."
  use GenServer
  require Logger
  alias Aiur.{Alerts, JsonStore}
  alias Aiur.Config.Paths
  alias Aiur.Orchestrator.DispatchPolicy

  @table :aiur_optimistic_starts
  @retention_ms 14 * 86_400_000
  @counters ~w(pushes_absorbed integrations_clean integrations_conflict non_ff_pushes parks resumes_after_park)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec record_start(String.t(), map()) :: :ok | {:error, atom()}
  def record_start(ticket, attrs), do: call({:start, ticket, attrs})

  @spec update_blocker(String.t(), String.t(), map()) :: :ok | {:error, atom()}
  def update_blocker(ticket, blocker, attrs), do: call({:update, ticket, {:blocker, blocker, attrs}})

  @spec bump(String.t(), atom() | String.t(), non_neg_integer()) :: :ok | {:error, atom()}
  def bump(ticket, counter, amount), do: call({:update, ticket, {:bump, to_string(counter), amount}})

  @spec set_status(String.t(), atom() | String.t(), integer()) :: :ok | {:error, atom()}
  def set_status(ticket, status, at_ms), do: call({:update, ticket, {:status, to_string(status), at_ms}})

  @spec close(String.t(), atom() | String.t(), integer()) :: :ok | {:error, atom()}
  def close(ticket, outcome, at_ms) do
    call({:update, ticket, {:close, to_string(outcome), at_ms}})
  end

  @spec close_observed(Aiur.Issue.t()) :: :ok | {:error, atom()}
  def close_observed(issue) do
    if DispatchPolicy.terminal_issue_state?(issue.state, DispatchPolicy.terminal_state_set()) or String.downcase(to_string(issue.state)) == "not_planned",
      do: close(issue.identifier, :discarded, System.system_time(:millisecond)),
      else: :ok
  end

  @spec get(String.t()) :: {:ok, map() | nil} | {:error, :ledger_unavailable}
  def get(ticket) do
    with {:ok, rows} <- records() do
      {:ok, rows |> Enum.filter(&(&1["ticket"] == ticket)) |> Enum.max_by(&attempt_order/1, fn -> nil end)}
    end
  end

  @spec open_records() :: {:ok, [map()]} | {:error, :ledger_unavailable}
  def open_records do
    with {:ok, rows} <- records(), do: {:ok, Enum.reject(rows, &(&1["status"] == "closed"))}
  end

  @spec by_blocker(String.t()) :: {:ok, [map()]} | {:error, :ledger_unavailable}
  def by_blocker(id) do
    with {:ok, rows} <- open_records(), do: {:ok, Enum.filter(rows, fn row -> Enum.any?(row["blockers"], &(&1["id"] == id)) end)}
  end

  defp records do
    case {Process.whereis(__MODULE__), :ets.lookup(@table, :records)} do
      {pid, [{:records, :available, rows}]} when is_pid(pid) -> {:ok, rows}
      _ -> {:error, :ledger_unavailable}
    end
  rescue
    ArgumentError -> {:error, :ledger_unavailable}
  end

  defp call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, reason ->
      Logger.warning("Optimistic ledger unavailable: #{inspect(reason)}")
      {:error, :ledger_unavailable}
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    state = %{path: nil, records: %{}, writable?: true, alert: Keyword.get(opts, :alert, &Alerts.emit_system/2)}

    case path(opts) do
      {:ok, path} -> load(%{state | path: path}, opts)
      {:error, reason} -> {:ok, unavailable(state, reason)}
    end
  end

  defp load(state, opts) do
    with {:ok, document} <- JsonStore.read(state.path, %{"v" => 1, "records" => %{}}),
         {:ok, rows, writable?} <- decode(document) do
      state = %{state | records: rows, writable?: writable?}
      now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
      kept = if writable?, do: prune(rows, now), else: rows
      state = if writable? and kept != rows, do: persist(state, kept), else: state
      publish(state)
      {:ok, state}
    else
      {:error, reason} -> {:ok, unavailable(state, reason)}
    end
  end

  @impl true
  def handle_call(_message, _from, %{writable?: false} = state), do: {:reply, {:error, :ledger_unavailable}, state}

  def handle_call({:start, ticket, attrs}, _from, state) do
    sequences = for {_id, %{"v" => 1} = row} <- state.records, do: row["attempt_sequence"] || 0

    record = %{
      "v" => 1,
      "ticket" => ticket,
      "attempt_id" => attrs.attempt_id,
      "attempt_sequence" => Enum.max(sequences, fn -> 0 end) + 1,
      "start_trigger" => to_string(attrs.start_trigger),
      "started_at_ms" => attrs.started_at_ms,
      "blockers" => attrs.blockers,
      "status" => "running",
      "outcome" => nil,
      "closed_at_ms" => nil,
      "counters" => Map.new(@counters, &{&1, 0})
    }

    if valid_record?(attrs.attempt_id, record), do: write_reply(state, Map.put_new(state.records, attrs.attempt_id, record)), else: {:reply, {:error, :invalid_record}, state}
  end

  def handle_call({:update, ticket, operation}, _from, state) do
    attempts = state.records |> Map.values() |> Enum.filter(&(&1["v"] == 1 and &1["ticket"] == ticket))
    latest = latest_id(attempts)
    current = attempts |> Enum.reject(&(&1["status"] == "closed")) |> latest_id()
    rows = Map.new(state.records, fn {id, row} -> {id, update_attempt(row, ticket, operation, current, latest)} end)
    write_reply(state, rows)
  end

  defp attempt_order(row), do: {row["attempt_sequence"] || 0, row["started_at_ms"], row["attempt_id"]}

  defp latest_id(attempts) do
    case Enum.max_by(attempts, &attempt_order/1, fn -> nil end) do
      nil -> nil
      row -> row["attempt_id"]
    end
  end

  defp update_attempt(%{"v" => 1, "ticket" => ticket} = row, ticket, operation, current, latest) do
    if row["status"] == "closed" do
      if row["attempt_id"] == latest and merged_correction?(row, operation), do: update(row, operation), else: row
    else
      if match?({:close, _, _}, operation) or row["attempt_id"] == current, do: update(row, operation), else: row
    end
  end

  defp update_attempt(row, _ticket, _operation, _current, _latest), do: row

  defp prune(rows, now) do
    Map.reject(rows, fn {_id, row} -> row["v"] == 1 and row["status"] == "closed" and row["closed_at_ms"] < now - @retention_ms end)
  end

  defp merged_correction?(%{"outcome" => "discarded"}, {:close, "merged", _at}), do: true
  defp merged_correction?(_row, _operation), do: false

  defp update(row, {:blocker, id, attrs}) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    Map.update!(
      row,
      "blockers",
      &Enum.map(&1, fn blocker -> if blocker["id"] == id, do: Map.merge(blocker, Map.drop(attrs, ["id", "pr_head_sha_at_start", "pr_head_ref_at_start"])), else: blocker end)
    )
  end

  defp update(row, {:bump, counter, amount}) when counter in @counters and is_integer(amount) and amount >= 0,
    do: update_in(row, ["counters", counter], &(&1 + amount))

  defp update(row, {:status, status, at}) when status in ["running", "parked"] and is_integer(at), do: Map.merge(row, %{"status" => status, "status_changed_at_ms" => at})

  defp update(row, {:close, outcome, at}) when outcome in ["merged", "merged_after_redo", "discarded"] and is_integer(at) do
    outcome = if outcome == "merged" and row["counters"]["parks"] > 0, do: "merged_after_redo", else: outcome
    Map.merge(row, %{"status" => "closed", "outcome" => outcome, "closed_at_ms" => at})
  end

  defp write_reply(state, rows) do
    next = if rows == state.records, do: state, else: persist(state, rows)
    {:reply, if(next.writable?, do: :ok, else: {:error, :ledger_unavailable}), next}
  end

  defp persist(state, rows) do
    JsonStore.write!(state.path, %{"v" => 1, "records" => rows})
    next = %{state | records: rows}
    publish(next)
    next
  rescue
    error -> unavailable(state, error)
  end

  defp publish(state) do
    supported? = Enum.all?(state.records, fn {_id, row} -> row["v"] == 1 end)
    availability = if state.writable? and supported?, do: :available, else: :unavailable
    visible = for {_id, %{"v" => 1} = row} <- state.records, do: row
    :ets.insert(@table, {:records, availability, visible})
  end

  defp unavailable(state, reason) do
    Logger.warning("Optimistic ledger unavailable: #{inspect(reason)}")
    latch = {__MODULE__, :alerted, Process.whereis(Aiur.Supervisor), state.path}

    unless :persistent_term.get(latch, false) do
      :persistent_term.put(latch, true)
      state.alert.("system.optimistic.ledger_unavailable", message: "Optimistic starts cannot be persisted", reason: inspect(reason), needs_attention: true)
    end

    next = %{state | writable?: false}
    publish(next)
    next
  end

  defp path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} -> {:ok, path}
      :error -> with {:ok, root} <- Paths.decision_state_dir(), do: {:ok, Path.join(root, "optimistic-starts.json")}
    end
  end

  defp decode(%{"v" => 1, "records" => rows}) when is_map(rows) do
    if Enum.all?(rows, fn {id, row} -> valid_record?(id, row) end), do: {:ok, rows, true}, else: {:error, :invalid_records}
  end

  defp decode(%{"v" => version, "records" => rows}) when is_integer(version) and version > 1 and is_map(rows), do: {:ok, rows, false}
  defp decode(_), do: {:error, :invalid_store}

  defp valid_record?(id, %{"v" => 1} = row) do
    row["attempt_id"] == id and is_binary(row["ticket"]) and is_integer(row["started_at_ms"]) and
      valid_sequence?(row["attempt_sequence"]) and
      valid_blockers?(row["blockers"]) and
      valid_counters?(row["counters"]) and
      row["status"] in ["running", "parked", "closed"] and (row["status"] != "closed" or is_integer(row["closed_at_ms"]))
  end

  defp valid_record?(_id, %{"v" => v}) when is_integer(v) and v > 1, do: true
  defp valid_record?(_id, _row), do: false

  defp valid_sequence?(nil), do: true
  defp valid_sequence?(sequence), do: is_integer(sequence) and sequence > 0

  defp valid_blockers?(blockers) when is_list(blockers), do: Enum.all?(blockers, &(is_map(&1) and is_binary(&1["id"])))
  defp valid_blockers?(_), do: false

  defp valid_counters?(counters) when is_map(counters), do: Enum.all?(@counters, &(is_integer(counters[&1]) and counters[&1] >= 0))
  defp valid_counters?(_), do: false
end
