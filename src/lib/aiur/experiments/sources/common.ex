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

  @spec events(String.t(), map(), map()) :: {:ok, [map()]} | {:error, term()}
  def events(ref, window, ctx) do
    case capture_error(ref, ctx) do
      nil ->
        case Map.fetch(ctx, :events) do
          {:ok, events} -> {:ok, select_events(events, ref, window)}
          :error -> read_events(ref, window, ctx)
        end

      reason ->
        {:error, reason}
    end
  end

  defp capture_error(ref, ctx) do
    server = Map.get(ctx, :capture_server, Capture)

    active = (is_pid(server) and Process.alive?(server)) or (is_atom(server) and not is_nil(Process.whereis(server)))
    injected = Enum.any?([:capture_root, :events, :capture_started_at], &Map.has_key?(ctx, &1))

    if not active and not injected do
      :capture_inactive
    else
      live_errors = if active, do: Capture.status(server).errors, else: %{}
      live_errors[ref] || disk_error(ref, ctx)
    end
  end

  defp disk_error(ref, ctx) do
    with {:ok, body} <- File.read(Path.join(capture_root(ctx), "errors.json")),
         {:ok, errors} when is_map(errors) <- Jason.decode(body) do
      errors[ref]
    else
      {:error, :enoent} -> nil
      _invalid -> :capture_corrupt
    end
  end

  defp read_events(ref, window, ctx) do
    capture_root(ctx)
    |> Path.join("events-*.ndjson")
    |> Path.wildcard()
    |> Enum.reduce_while({:ok, []}, &read_event_file/2)
    |> case do
      {:ok, events} -> {:ok, select_events(events, ref, window)}
      error -> error
    end
  end

  defp read_event_file(path, {:ok, events}) do
    with {:ok, body} <- File.read(path),
         {:ok, lines} <- decode_events(body) do
      {:cont, {:ok, events ++ lines}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

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
    case Map.fetch(ctx, :capture_started_at) do
      {:ok, started} when is_map(started) and not is_struct(started) ->
        started[ref]

      {:ok, started} ->
        started

      :error ->
        with {:ok, body} <- File.read(Path.join(capture_root(ctx), "coverage.json")),
             {:ok, metadata} when is_map(metadata) <- Jason.decode(body) do
          metadata[ref]
        else
          _missing -> nil
        end
    end
  end

  @spec facts(map()) :: [String.t()]
  def facts(attrs), do: for({key, value} <- attrs, not is_nil(value), do: key)

  @spec result(map(), [Observation.t()]) :: map()
  def result(coverage, observations), do: %{coverage: coverage, observations: observations}

  @spec unavailable(term()) :: map()
  def unavailable(reason), do: result(%{state: :unavailable, reason: reason}, [])
end
