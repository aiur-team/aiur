defmodule Aiur.Experiments.Capture do
  @moduledoc "Journals declared consumer fields; keeps subscription and durable coverage transitions in one process."
  use GenServer
  require Logger

  alias Aiur.{Events, Events.Exchange}
  alias Aiur.Experiments.Capture.{Fields, Retention}
  alias Aiur.Experiments.{Catalog, Paths}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    state = %{
      context: Keyword.get(opts, :context, %{}),
      root: Keyword.get(opts, :root, Path.join(Paths.root(), "capture")),
      exchange: Keyword.get(opts, :exchange, Exchange),
      interval: Keyword.get(opts, :refresh_interval, 60_000),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      append: Keyword.get(opts, :append, &Aiur.Journal.append/2),
      alert: Keyword.get(opts, :alert, &alert/1),
      write: Keyword.get(opts, :write, &Aiur.Fs.atomic_write/3),
      queue_limit: Keyword.get(opts, :queue_limit, 1024),
      exchange_monitor: nil,
      exchange_pid: nil,
      persisted: %{},
      problem_hashes: %{},
      metrics: %{},
      patterns: MapSet.new(),
      coverage: %{},
      errors: %{},
      dropped: 0,
      seen: []
    }

    state = reload(state)
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state), do: {:reply, :ok, reload(state)}
  def handle_call(:status, _from, state), do: {:reply, Map.take(state, [:coverage, :errors, :dropped]), state}

  @impl true
  def handle_info(:refresh, state) do
    state = reload(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info({:event, event}, state) when is_map(event) do
    id = Fields.get(event, "id")

    {:message_queue_len, queued} = Process.info(self(), :message_queue_len)

    if queued >= state.queue_limit do
      {:noreply, drop_event(event, state) |> persist_metadata()}
    else
      capture_once(event, id, state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{exchange_monitor: ref} = state) do
    state = exchange_lost(state) |> persist_metadata()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp capture_once(event, id, state) do
    if id && id in state.seen do
      {:noreply, state}
    else
      state = capture(event, state)
      seen = if id, do: Enum.take([id | state.seen], 1024), else: state.seen
      {:noreply, %{state | seen: seen}}
    end
  end

  defp schedule(state), do: Process.send_after(self(), :refresh, state.interval)

  defp reload(state) do
    catalog = Catalog.load(state.context)
    state = report_problems(catalog.problems, state)
    metrics = catalog.metrics |> Map.filter(fn {_ref, metric} -> event_source?(metric.source) end)
    patterns = metrics |> Enum.flat_map(fn {_ref, metric} -> patterns(metric.source) end) |> MapSet.new()
    state = bind_exchange(state, patterns)
    now = DateTime.to_iso8601(state.clock.())

    coverage =
      Map.new(metrics, fn {ref, metric} ->
        started = if state.metrics[ref] == metric, do: state.coverage[ref] || now, else: now
        {ref, started}
      end)

    coverage = if state.exchange_monitor, do: coverage, else: %{}
    state = %{state | metrics: metrics, coverage: coverage, errors: Map.take(state.errors, Map.keys(metrics))}
    state = if state.exchange_monitor, do: state, else: exchange_lost(state)
    state = persist_metadata(state)
    Retention.run(state.root, state.clock.())
    state
  end

  defp bind_exchange(state, patterns) do
    case GenServer.whereis(state.exchange) do
      nil ->
        exchange_lost(state)

      pid ->
        bind_live_exchange(state, patterns, pid)
    end
  catch
    :exit, _reason -> exchange_lost(state)
  end

  defp bind_live_exchange(state, patterns, pid) do
    if Process.alive?(pid) do
      state = if state.exchange_pid == pid, do: state, else: exchange_restored(state, pid)
      Enum.each(MapSet.difference(state.patterns, patterns), &Events.unsubscribe(&1, state.exchange))
      Enum.each(MapSet.difference(patterns, state.patterns), &Events.subscribe(&1, state.exchange))
      %{state | patterns: patterns}
    else
      exchange_lost(state)
    end
  end

  defp exchange_restored(state, pid) do
    if state.exchange_monitor, do: Process.demonitor(state.exchange_monitor, [:flush])
    errors = Map.reject(state.errors, fn {_ref, reason} -> reason == ":exchange_unavailable" end)
    %{state | exchange_monitor: Process.monitor(pid), exchange_pid: pid, metrics: %{}, patterns: MapSet.new(), errors: errors, seen: []}
  end

  defp exchange_lost(state) do
    if state.exchange_monitor, do: Process.demonitor(state.exchange_monitor, [:flush])
    errors = Enum.reduce(Map.keys(state.metrics), state.errors, &Map.put_new(&2, &1, ":exchange_unavailable"))
    %{state | exchange_monitor: nil, exchange_pid: nil, patterns: MapSet.new(), coverage: %{}, errors: errors}
  end

  defp drop_event(event, state) do
    topic = Fields.get(event, "topic")

    errors =
      Enum.reduce(state.metrics, state.errors, fn {ref, metric}, errors ->
        if is_binary(topic) and Enum.any?(patterns(metric.source), &Events.matches?(&1, topic)),
          do: Map.put_new(errors, ref, ":capture_overloaded"),
          else: errors
      end)

    %{state | errors: errors, dropped: state.dropped + 1}
  end

  defp report_problems(problems, state) do
    hashes =
      Map.new(Enum.group_by(problems, & &1.file), fn {file, entries} ->
        content =
          case File.read(file) do
            {:ok, bytes} -> bytes
            _error -> inspect(entries)
          end

        hash = :crypto.hash(:sha256, content)
        if state.problem_hashes[file] != hash, do: state.alert.("Invalid experiment metric pack #{file}: #{inspect(entries)}")
        {file, hash}
      end)

    %{state | problem_hashes: hashes}
  end

  defp alert(message) do
    Aiur.Alerts.emit_system("system.experiments.pack_invalid", message: message, needs_attention: true)
  rescue
    error -> Logger.warning("experiment pack alert unavailable: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("experiment pack alert unavailable: #{inspect(reason)}")
  end

  defp event_source?(%{"kind" => kind}), do: kind in ["event_interval", "event_count"]
  defp event_source?(_source), do: false
  defp patterns(%{"kind" => "event_interval"} = source), do: [source["start"], source["end"]]
  defp patterns(source), do: [source["match"]]

  defp capture(event, state) do
    topic = Fields.get(event, "topic")

    if is_binary(topic) do
      Enum.reduce(state.metrics, state, &capture_metric(&1, &2, topic, event))
    else
      state
    end
  end

  defp capture_metric({ref, metric}, state, topic, event) do
    cond do
      not Enum.any?(patterns(metric.source), &Events.matches?(&1, topic)) -> state
      Map.has_key?(state.errors, ref) -> %{state | dropped: state.dropped + 1}
      true -> append(ref, metric.source, event, state)
    end
  end

  defp append(ref, source, event, state) do
    at = event_time(event, state.clock)
    payload = Fields.get(event, "payload") || event
    attrs = Map.new(source["attrs"] || %{}, fn {key, pointer} -> {key, Fields.extract(payload, pointer)} end)
    unit = Fields.unit(payload, Fields.get(event, "topic"), source["unit_key"])
    row = %{"metric_ref" => ref, "topic" => Fields.get(event, "topic"), "at" => at, "unit" => unit, "attrs" => attrs}
    path = Path.join(state.root, "events-#{String.slice(at, 0, 7)}.ndjson")

    case state.append.(path, row) do
      :ok -> state
      {:error, reason} -> failed(state, ref, reason) |> persist_metadata()
    end
  end

  defp event_time(event, clock) do
    observed = Fields.get(event, "ticket_observation")
    candidate = Fields.get(event, "at") || if(is_map(observed), do: Fields.get(observed, "occurred_at") || Fields.get(observed, "observed_at"))

    case candidate do
      %DateTime{} = at ->
        DateTime.to_iso8601(at)

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, at, _offset} -> DateTime.to_iso8601(at)
          _invalid -> DateTime.to_iso8601(clock.())
        end

      _missing ->
        DateTime.to_iso8601(clock.())
    end
  end

  defp persist_metadata(state) do
    Enum.reduce([:coverage, :errors], state, fn key, state ->
      value = Map.fetch!(state, key)

      if state.persisted[key] == value do
        state
      else
        write_metadata(state, key, value)
      end
    end)
  end

  defp write_metadata(state, key, value) do
    state = %{state | persisted: Map.put(state.persisted, key, value)}

    with :ok <- Aiur.Journal.ensure_directory(state.root),
         :ok <- state.write.(Path.join(state.root, "#{key}.json"), Jason.encode!(value), fsync: true, mode: 0o600) do
      state
    else
      {:error, reason} -> Enum.reduce(Map.keys(state.metrics), state, &failed(&2, &1, reason))
    end
  end

  defp failed(state, ref, reason) do
    Logger.warning("experiment capture dropped data: #{inspect(reason)}")
    %{state | errors: Map.put(state.errors, ref, inspect(reason)), dropped: state.dropped + 1}
  end
end
