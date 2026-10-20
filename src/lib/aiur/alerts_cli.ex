defmodule Aiur.AlertsCLI do
  @moduledoc false

  alias Aiur.{AlertFeed, AlertLedger}

  @default_limit 100

  @usage "aiur: alerts accepts --needs-attention, --limit <n>, --all, ack ticket.<id>.agent.attention.duplicate-dispatch --executor-id <id>"

  @spec parse([String.t()]) :: {:ok, keyword()} | {:error, String.t()}
  def parse(argv), do: parse(argv, [])

  defp parse([], acc), do: {:ok, acc}
  defp parse(["--needs-attention" | rest], acc), do: parse(rest, [{:needs_attention, true} | acc])
  defp parse(["--all" | rest], acc), do: parse(rest, [{:limit, :all} | acc])

  defp parse(["ack", topic, "--executor-id", executor_id], []) do
    if valid_attention_topic?(topic) and String.trim(executor_id) != "" do
      {:ok, [ack: topic, executor_id: executor_id]}
    else
      {:error, "aiur: alerts ack requires an attention topic and non-empty --executor-id"}
    end
  end

  defp parse(["--limit", n | rest], acc) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> parse(rest, [{:limit, i} | acc])
      _ -> {:error, "aiur: alerts --limit needs a positive integer"}
    end
  end

  defp parse(_, _), do: {:error, @usage}

  # Open attention items are never cut: only the other history rows are capped.
  @spec run(keyword()) :: 0 | 1 | 64
  def run(argv: argv) do
    case parse(argv) do
      {:ok, opts} ->
        run(opts)

      {:error, msg} ->
        IO.puts(:stderr, msg)
        64
    end
  end

  def run(opts) do
    case Keyword.fetch(opts, :ack) do
      {:ok, topic} ->
        if valid_attention_topic?(topic) do
          acknowledge(topic, Keyword.fetch!(opts, :executor_id), opts)
        else
          IO.puts(:stderr, @usage)
          64
        end

      :error ->
        list_alerts(opts)
    end
  end

  defp list_alerts(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    alerts = opts |> Keyword.delete(:limit) |> AlertFeed.list() |> Enum.with_index()
    others = Enum.reject(alerts, fn {a, _} -> a["needs_attention"] == true end)
    omitted = if limit == :all, do: 0, else: max(length(others) - limit, 0)

    if omitted > 0 do
      IO.puts(
        Jason.encode!(%{
          "event" => "alert_feed_truncated",
          "limit" => limit,
          "omitted_count" => omitted,
          "message" => "Showing latest #{limit} non-attention alerts plus all open attention items; #{omitted} older omitted (use --all or --limit N)"
        })
      )
    end

    dropped = others |> Enum.take(omitted) |> MapSet.new(&elem(&1, 1))

    alerts
    |> Enum.reject(fn {_, i} -> MapSet.member?(dropped, i) end)
    |> Enum.map(fn {a, _} -> [Jason.encode!(a), "\n"] end)
    |> IO.write()

    0
  end

  defp acknowledge(topic, executor_id, opts) do
    if AlertFeed.condition_state(
         topic,
         Keyword.take(opts, [:ledger_path, :ledger_paths, :log_roots])
       ) == :firing do
      append_acknowledgment(topic, executor_id, opts)
    else
      IO.puts(:stderr, "aiur: attention is not currently active: #{topic}")
      1
    end
  end

  defp append_acknowledgment(topic, executor_id, opts) do
    entry = %{
      "event" => "alert",
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "topic" => topic <> ".resolved",
      "name" => topic <> ".resolved",
      "message" => "Attention acknowledged by #{executor_id}",
      "reason" => "Acknowledged by Executor.",
      "needs_attention" => false,
      "agent" => "system",
      "acknowledged_by" => %{"kind" => "executor", "id" => executor_id}
    }

    case AlertLedger.append(entry, Keyword.take(opts, [:ledger_path, :ledger_paths, :log_roots])) do
      :ok ->
        IO.puts("Acknowledged #{topic} as #{executor_id}")
        0

      {:error, reason} ->
        IO.puts(:stderr, "aiur: unable to acknowledge attention (#{inspect(reason)})")
        1
    end
  end

  defp valid_attention_topic?("ticket." <> rest) do
    case String.split(rest, ".agent.attention.", parts: 2) do
      [ticket, "duplicate-dispatch"] when ticket != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_attention_topic?(_topic), do: false
end
