defmodule Aiur.Listener.Spec do
  @moduledoc "Boot-cached reader for the pinned Khala listener v1 build-time contract."
  require Logger

  alias Aiur.Listener.Spec.Integrity

  @type status :: :ok | {:error, :not_installed | :spec_invalid}

  @doc "Validate the installed contract once per boot. Missing or invalid assets fail closed."
  @spec status() :: status()
  def status, do: status(root())

  @doc false
  @spec status(Path.t()) :: status()
  def status(path) do
    case snapshot(path) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Scheduler truth-table rows, or the installation error."
  @spec scheduler_rows() :: [map()] | {:error, :not_installed | :spec_invalid}
  def scheduler_rows, do: value(:scheduler_rows)

  @doc "Support status strings from the shared schema, or the installation error."
  @spec support_statuses() :: [String.t()] | {:error, :not_installed | :spec_invalid}
  def support_statuses, do: value(:support_statuses)

  @doc "Mode strings from the shared schema (the listener's default remains sync)."
  @spec modes() :: [String.t()] | {:error, :not_installed | :spec_invalid}
  def modes, do: value(:modes)

  defp root, do: Application.app_dir(:aiur, "priv/listener_spec")

  defp value(key) do
    case snapshot(root()) do
      {:ok, data} -> Map.fetch!(data, key)
      error -> error
    end
  end

  defp snapshot(path) do
    key = {__MODULE__, path}

    :global.trans({key, self()}, fn ->
      case :persistent_term.get(key, :unread) do
        :unread -> cache(key, path)
        result -> result
      end
    end)
  end

  defp cache(key, path) do
    result = load(path)
    if match?({:error, _}, result), do: Logger.warning("Listener spec unavailable: #{inspect(result)}")
    :persistent_term.put(key, result)
    result
  end

  defp load(path) do
    with {:ok, documents} <- Integrity.read(path),
         {:ok, projection} <- project(documents) do
      {:ok, projection}
    else
      {:error, :not_installed} = error -> error
      _ -> {:error, :spec_invalid}
    end
  end

  defp project(documents) do
    schema = documents["v1/listening-mode.v1.schema.json"]
    modes = get_in(schema, ["$defs", "mode", "enum"])
    statuses = get_in(schema, ["$defs", "supportEntry", "properties", "status", "enum"])
    rows = documents["v1/scheduler.v1.json"]

    if modes == ["steer", "sync", "async", "mute"] and strings?(statuses) and valid_rows?(rows, modes) do
      {:ok, %{modes: modes, support_statuses: statuses, scheduler_rows: rows}}
    else
      {:error, :spec_invalid}
    end
  rescue
    _ in [FunctionClauseError, BadMapError, ArgumentError] -> {:error, :spec_invalid}
  end

  defp strings?(values), do: is_list(values) and values != [] and Enum.all?(values, &is_binary/1)

  defp valid_rows?(rows, modes) when is_list(rows) and rows != [] do
    Enum.all?(rows, &valid_row?(&1, modes))
  end

  defp valid_rows?(_, _), do: false

  defp valid_row?(%{"mode" => mode, "harness" => harness, "event" => event, "busy_age_ms" => age} = row, modes) do
    mode in modes and harness in ["claude", "codex"] and event in ["start", "prompt", "tool", "stop", "limit"] and
      (is_nil(age) or (is_integer(age) and age >= 0)) and
      Enum.all?(["busy", "continuation", "delivers", "interrupted_since_busy", "mark_idle_only"], &is_boolean(row[&1]))
  end

  defp valid_row?(_, _), do: false
end
