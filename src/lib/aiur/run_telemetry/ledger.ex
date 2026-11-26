defmodule Aiur.RunTelemetry.Ledger do
  @moduledoc "Reads canonical Python-derived ticket records; never re-derives facts."
  require Logger
  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Summaries

  @spec schema_version() :: pos_integer()
  def schema_version, do: 1

  @spec get(String.t()) :: {:ok, map()} | {:error, atom()}
  def get(ticket) when is_binary(ticket) do
    cond do
      not RunTelemetry.telemetry_enabled?() -> {:error, :disabled}
      ticket in ["", ".", ".."] or String.contains?(ticket, ["/", "\\"]) -> {:error, :invalid_ticket}
      true -> read(Path.join(Summaries.ledger_dir(), ticket <> ".json"))
    end
  end

  @doc "Lists records by last-event window and exact cohort fields; corrupt records are logged and skipped."
  @spec list(keyword()) :: {:ok, [map()]} | {:error, atom()}
  def list(opts \\ []) do
    if RunTelemetry.telemetry_enabled?() do
      records =
        Summaries.ledger_dir()
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.flat_map(&read_matching(&1, opts))

      {:ok, records}
    else
      {:error, :disabled}
    end
  end

  defp read_matching(path, opts) do
    case read(path) do
      {:ok, record} ->
        if matches?(record, opts), do: [record], else: []

      {:error, reason} ->
        Logger.warning("ticket_ledger unreadable path=#{path} reason=#{reason}")
        []
    end
  end

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"schema_version" => 1, "ticket" => ticket, "milestones" => milestones} = record} <- Jason.decode(body),
         true <- is_binary(ticket) and is_map(milestones) and is_map(record["cohort"]) and is_binary(record["last_event_at"]) do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, :missing}
      _other -> {:error, :invalid_record}
    end
  end

  defp matches?(record, opts) do
    cohort = Keyword.get(opts, :cohort, %{})

    Enum.all?(cohort, fn {key, value} -> get_in(record, ["cohort", to_string(key)]) == value end) and
      in_window?(record["last_event_at"], Keyword.get(opts, :window))
  end

  defp in_window?(_at, nil), do: true

  defp in_window?(at, {from, to}) do
    with {:ok, timestamp, _} <- DateTime.from_iso8601(at),
         {:ok, start} <- datetime(from),
         {:ok, finish} <- datetime(to) do
      DateTime.compare(timestamp, start) != :lt and DateTime.compare(timestamp, finish) != :gt
    else
      _other -> false
    end
  end

  defp datetime(%DateTime{} = value), do: {:ok, value}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _} -> {:ok, timestamp}
      _other -> :error
    end
  end
end
