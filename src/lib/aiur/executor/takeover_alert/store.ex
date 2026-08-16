defmodule Aiur.Executor.TakeoverAlert.Store do
  @moduledoc false

  # Daemon-private durable store for the Executor takeover-alert monitor.
  #
  # Persists per-ticket convergence anchors, alert-cadence state, dispatch
  # counting and cached open-PR evidence to a JSON file under the daemon state
  # root so worker restart, `max_turns` recycle and daemon restart never reset
  # a convergence clock or re-fire a first alert.

  use GenServer

  require Logger

  alias Aiur.Config.Paths

  @filename "takeover-alerts.json"
  @default_timeout 5_000

  @type record :: %{
          anchor_at: DateTime.t() | nil,
          last_alert_at: DateTime.t() | nil,
          dispatches: non_neg_integer(),
          live_owner?: boolean(),
          pr: map() | nil,
          pr_checked_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec state_dir(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def state_dir(opts \\ []) do
    case Keyword.get(opts, :state_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> Paths.takeover_alert_state_dir()
    end
  end

  @spec path(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def path(opts \\ []) do
    with {:ok, dir} <- state_dir(opts), do: {:ok, Path.join(dir, @filename)}
  end

  @doc """
  Records one observation of a nonterminal in-scope ticket.

  Ensures the durable `anchor_at` (set once, never reset), updates the live
  owner state and increments `dispatches` on a false→true owner transition
  (a durable proxy for worker dispatch/restart episodes). Returns the updated
  record.
  """
  @spec observe(String.t(), boolean(), DateTime.t(), GenServer.server()) :: record()
  def observe(identifier, live_owner?, now, server \\ __MODULE__) do
    GenServer.call(server, {:observe, identifier, live_owner?, now}, @default_timeout)
  end

  @doc "Caches open-PR evidence (with `refreshed_at` = `now`) for a ticket; `nil` records a checked-but-no-PR result."
  @spec record_pr(String.t(), map() | nil, DateTime.t(), GenServer.server()) :: record()
  def record_pr(identifier, pr, now, server \\ __MODULE__) do
    GenServer.call(server, {:record_pr, identifier, pr, now}, @default_timeout)
  end

  @doc "Records that a takeover advisory fired at `now` (drives the repeat cadence)."
  @spec record_alert(String.t(), DateTime.t(), GenServer.server()) :: record()
  def record_alert(identifier, now, server \\ __MODULE__) do
    GenServer.call(server, {:record_alert, identifier, now}, @default_timeout)
  end

  @doc """
  Forgets a ticket's convergence state (terminal / out of scope). Returns
  `{:ok, had_alert?}` so the caller can emit a resolution only when an alert
  had actually been active.
  """
  @spec forget(String.t(), GenServer.server()) :: {:ok, boolean()}
  def forget(identifier, server \\ __MODULE__) do
    GenServer.call(server, {:forget, identifier}, @default_timeout)
  end

  @doc "Returns a ticket's stored record, or `nil` when it has no state."
  @spec record(String.t(), GenServer.server()) :: record() | nil
  def record(identifier, server \\ __MODULE__) do
    GenServer.call(server, {:record, identifier}, @default_timeout)
  end

  @impl true
  def init(opts) do
    case path(opts) do
      {:ok, path} ->
        {:ok, %{path: path, records: load_records(path)}}

      {:error, reason} ->
        {:stop, {:takeover_alert_state_dir_unavailable, reason}}
    end
  end

  @impl true
  def handle_call({:observe, identifier, live_owner?, now}, _from, state) do
    previous = Map.get(state.records, identifier, new_record())
    record = previous |> ensure_anchor(now) |> observe_owner(live_owner?)

    if record == previous do
      {:reply, record, state}
    else
      {:reply, record, put_record(state, identifier, record)}
    end
  end

  def handle_call({:record_pr, identifier, pr, now}, _from, state) do
    record = Map.get(state.records, identifier) || new_record()
    record = %{record | pr: normalize_pr(pr, now), pr_checked_at: now}
    {:reply, record, put_record(state, identifier, record)}
  end

  def handle_call({:record_alert, identifier, now}, _from, state) do
    record = Map.get(state.records, identifier) || new_record()
    record = %{record | last_alert_at: now}
    {:reply, record, put_record(state, identifier, record)}
  end

  def handle_call({:forget, identifier}, _from, state) do
    case Map.get(state.records, identifier) do
      nil ->
        {:reply, {:ok, false}, state}

      record ->
        had_alert? = match?(%{last_alert_at: %DateTime{}}, record)
        {:reply, {:ok, had_alert?}, put_record(state, identifier, nil)}
    end
  end

  def handle_call({:record, identifier}, _from, state) do
    {:reply, Map.get(state.records, identifier), state}
  end

  defp put_record(state, identifier, nil) do
    state = %{state | records: Map.delete(state.records, identifier)}
    persist(state)
    state
  end

  defp put_record(state, identifier, record) do
    state = %{state | records: Map.put(state.records, identifier, record)}
    persist(state)
    state
  end

  defp new_record do
    %{
      anchor_at: nil,
      last_alert_at: nil,
      dispatches: 0,
      live_owner?: false,
      pr: nil,
      pr_checked_at: nil
    }
  end

  defp ensure_anchor(%{anchor_at: nil} = record, now), do: %{record | anchor_at: now}
  defp ensure_anchor(record, _now), do: record

  defp observe_owner(%{live_owner?: previous} = record, live_owner?) do
    dispatches = if live_owner? and not previous, do: record.dispatches + 1, else: record.dispatches
    %{record | live_owner?: live_owner?, dispatches: dispatches}
  end

  defp normalize_pr(nil, _now), do: nil

  defp normalize_pr(pr, now) when is_map(pr) do
    %{
      number: Map.get(pr, :number),
      created_at: Map.get(pr, :created_at),
      pushed_at: Map.get(pr, :pushed_at),
      mergeable_state: Map.get(pr, :mergeable_state),
      ci_state: Map.get(pr, :ci_state),
      refreshed_at: now
    }
  end

  # ---- persistence ----

  defp load_records(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, decoded} when is_map(decoded) ->
            Map.new(decoded, fn {identifier, raw} -> {identifier, decode_record(raw)} end)

          _ ->
            Logger.warning("executor_takeover_alert_state unreadable path=#{path}")
            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("executor_takeover_alert_state read_failed path=#{path} reason=#{inspect(reason)}")
        %{}
    end
  rescue
    error ->
      Logger.warning("executor_takeover_alert_state load_error path=#{path} error=#{Exception.message(error)}")
      %{}
  end

  defp decode_record(raw) when is_map(raw) do
    %{
      anchor_at: decode_datetime(Map.get(raw, "anchor_at")),
      last_alert_at: decode_datetime(Map.get(raw, "last_alert_at")),
      dispatches: Map.get(raw, "dispatches", 0) || 0,
      live_owner?: Map.get(raw, "live_owner", false) == true,
      pr: decode_pr(Map.get(raw, "pr")),
      pr_checked_at: decode_datetime(Map.get(raw, "pr_checked_at"))
    }
  end

  defp decode_record(_raw), do: new_record()

  defp decode_pr(nil), do: nil

  defp decode_pr(raw) when is_map(raw) do
    %{
      number: Map.get(raw, "number"),
      created_at: decode_datetime(Map.get(raw, "created_at")),
      pushed_at: decode_datetime(Map.get(raw, "pushed_at")),
      mergeable_state: Map.get(raw, "mergeable_state"),
      ci_state: Map.get(raw, "ci_state"),
      refreshed_at: decode_datetime(Map.get(raw, "refreshed_at"))
    }
  end

  defp decode_pr(_raw), do: nil

  defp decode_datetime(nil), do: nil

  defp decode_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp decode_datetime(_value), do: nil

  defp persist(state) do
    encoded = Jason.encode!(encode_records(state.records))

    case File.mkdir_p(Path.dirname(state.path)) do
      :ok ->
        temp = state.path <> ".tmp"

        with :ok <- File.write(temp, encoded),
             :ok <- File.rename(temp, state.path) do
          :ok
        else
          {:error, reason} ->
            Logger.warning("executor_takeover_alert_state write_failed path=#{state.path} reason=#{inspect(reason)}")
            :ok
        end

      {:error, reason} ->
        Logger.warning("executor_takeover_alert_state mkdir_failed path=#{state.path} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp encode_records(records) do
    Map.new(records, fn {identifier, record} -> {identifier, encode_record(record)} end)
  end

  defp encode_record(record) do
    %{
      "anchor_at" => encode_datetime(record.anchor_at),
      "last_alert_at" => encode_datetime(record.last_alert_at),
      "dispatches" => record.dispatches,
      "live_owner" => record.live_owner?,
      "pr" => encode_pr(record.pr),
      "pr_checked_at" => encode_datetime(record.pr_checked_at)
    }
  end

  defp encode_pr(nil), do: nil

  defp encode_pr(pr) do
    %{
      "number" => Map.get(pr, :number),
      "created_at" => encode_datetime(Map.get(pr, :created_at)),
      "pushed_at" => encode_datetime(Map.get(pr, :pushed_at)),
      "mergeable_state" => Map.get(pr, :mergeable_state),
      "ci_state" => Map.get(pr, :ci_state),
      "refreshed_at" => encode_datetime(Map.get(pr, :refreshed_at))
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(_other), do: nil
end
