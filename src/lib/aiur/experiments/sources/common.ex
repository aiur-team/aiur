defmodule Aiur.Experiments.Sources.Common do
  @moduledoc false

  alias Aiur.Experiments.{Capture, Coverage, Observation, Paths}

  @spec repo_path(map()) :: Path.t()
  def repo_path(ctx), do: Map.get_lazy(ctx, :repo_path, fn -> Aiur.RepoBase.base_path(Paths.repo()) end)

  @spec capture_root(map()) :: Path.t()
  def capture_root(ctx), do: Map.get_lazy(ctx, :capture_root, fn -> Path.join(Paths.root(), "capture") end)

  @spec in_window?(DateTime.t(), map()) :: boolean()
  def in_window?(at, window), do: DateTime.compare(at, window.start) != :lt and DateTime.compare(at, window.end) == :lt

  @spec timestamp(term()) :: DateTime.t() | nil
  def timestamp(%DateTime{} = at), do: at

  def timestamp(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> parsed
      _invalid -> nil
    end
  end

  def timestamp(_at), do: nil

  @spec prepare_context(map(), map()) :: map()
  def prepare_context(window, ctx) do
    server = Map.get(ctx, :capture_server, Capture)
    active = (is_pid(server) and Process.alive?(server)) or (is_atom(server) and not is_nil(Process.whereis(server)))
    injected = Enum.any?([:capture_root, :events, :capture_started_at], &Map.has_key?(ctx, &1))

    snapshot =
      if not active and not injected do
        %{events: {:error, :capture_inactive}, errors: %{}, live_errors: %{}, started: nil}
      else
        capture_snapshot(window, ctx, server, active)
      end

    Map.put(ctx, :capture_snapshot, snapshot)
  end

  defp capture_snapshot(window, ctx, server, active) do
    status = if active, do: Map.get(ctx, :capture_status, &Capture.status/1).(server), else: %{errors: %{}}
    errors = read_metadata("errors.json", ctx, :capture_corrupt)
    started = Map.get_lazy(ctx, :capture_started_at, fn -> read_metadata("coverage.json", ctx, nil) end)
    events = if Map.has_key?(ctx, :events), do: {:ok, ctx.events}, else: read_events(window, ctx)
    %{events: events, errors: errors, live_errors: status.errors, started: started}
  end

  @spec events(String.t(), map(), map()) :: {:ok, [map()]} | {:error, term()}
  def events(ref, window, ctx) do
    snapshot = Map.get_lazy(ctx, :capture_snapshot, fn -> prepare_context(window, ctx).capture_snapshot end)
    reason = snapshot.live_errors[ref] || if(is_map(snapshot.errors), do: snapshot.errors[ref], else: snapshot.errors)

    case {reason, snapshot.events} do
      {nil, {:ok, events}} -> {:ok, select_events(events, ref, window)}
      {nil, error} -> error
      {reason, _events} -> {:error, reason}
    end
  end

  defp read_metadata(file, ctx, invalid) do
    with {:ok, body} <- read_file(Path.join(capture_root(ctx), file), ctx),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(body) do
      metadata
    else
      {:error, :enoent} -> %{}
      _invalid -> invalid
    end
  end

  defp read_file(path, ctx), do: Map.get(ctx, :capture_read, &File.read/1).(path)

  defp read_events(window, ctx) do
    first = month(window.start)
    last = month(DateTime.add(window.end, -1, :microsecond))

    capture_root(ctx)
    |> Path.join("events-*.ndjson")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      name = Path.basename(path)
      name >= "events-#{first}.ndjson" and name <= "events-#{last}.ndjson"
    end)
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, events} ->
      with {:ok, body} <- read_file(path, ctx),
           {:ok, lines} <- decode_events(body) do
        {:cont, {:ok, lines ++ events}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp month(at), do: Calendar.strftime(at, "%Y-%m")

  defp decode_events(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, &decode_event_line/2)
  end

  defp decode_event_line(line, {:ok, rows}) do
    case Jason.decode(line) do
      {:ok, %{"metric_ref" => ref, "topic" => topic, "at" => at} = event} when is_binary(ref) and is_binary(topic) ->
        if timestamp(at) && valid_fields?(event), do: {:cont, {:ok, [event | rows]}}, else: {:halt, {:error, :capture_corrupt}}

      _invalid ->
        {:halt, {:error, :capture_corrupt}}
    end
  end

  defp valid_fields?(event), do: (is_nil(event["unit"]) or is_binary(event["unit"])) and is_map(event["attrs"] || %{})

  defp select_events(events, ref, window) do
    events
    |> Enum.flat_map(fn event ->
      at = timestamp(event["at"])
      if (event["metric_ref"] == ref and at) && in_window?(at, window), do: [Map.put(event, "at", at)], else: []
    end)
    |> Enum.sort_by(& &1["at"], DateTime)
  end

  @spec event_coverage(term(), String.t(), [map()], map(), map()) :: map()
  def event_coverage(metric, ref, events, window, ctx) do
    started = timestamp(capture_started_at(ref, ctx))
    facts = Map.get(ctx, :data_facts, Enum.flat_map(events, &facts(&1["attrs"] || %{})))

    if is_nil(started) do
      %{state: :not_captured}
    else
      Coverage.classify(metric.requires, facts, window, timestamp(started))
    end
  end

  defp capture_started_at(ref, ctx) do
    started =
      case Map.fetch(ctx, :capture_snapshot) do
        {:ok, snapshot} -> snapshot.started
        :error -> Map.get_lazy(ctx, :capture_started_at, fn -> read_metadata("coverage.json", ctx, nil) end)
      end

    if is_map(started) and not is_struct(started), do: started[ref], else: started
  end

  @spec facts(map()) :: [String.t()]
  def facts(attrs), do: for({key, value} <- attrs, not is_nil(value), do: key)

  @spec result(map(), [Observation.t()]) :: map()
  def result(coverage, observations), do: %{coverage: coverage, observations: observations}

  @spec unavailable(term()) :: map()
  def unavailable(reason), do: result(%{state: :unavailable, reason: reason}, [])
end
