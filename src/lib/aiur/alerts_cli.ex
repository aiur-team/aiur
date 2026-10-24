defmodule Aiur.AlertsCLI do
  @moduledoc false

  alias Aiur.{AlertFeed, AlertLedger}

  @default_limit 100
  @retention_days 14

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

  # Open attention items print first, then the latest `limit` other rows.
  # Items opened before the retention window are counted, not listed, unless
  # `--all` asks for everything.
  defp list_alerts(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    cutoff = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.add(-@retention_days * 86_400)
    alerts = opts |> Keyword.drop([:limit, :now]) |> AlertFeed.list()
    {open, others} = Enum.split_with(alerts, &(&1["needs_attention"] == true))
    {archived, open} = if limit == :all, do: {[], open}, else: Enum.split_with(open, &opened_before?(&1, cutoff))
    omitted = if limit == :all, do: 0, else: max(length(others) - limit, 0)

    print(%{
      "event" => "alert_feed_summary",
      "open_count" => length(open),
      "archived_count" => length(archived),
      "retention_days" => @retention_days,
      "history_count" => length(others) - omitted
    })

    if omitted > 0 do
      print(%{
        "event" => "alert_feed_truncated",
        "limit" => limit,
        "omitted_count" => omitted,
        "message" => "Showing latest #{limit} non-attention alerts plus all open attention items; #{omitted} older omitted (use --all or --limit N)"
      })
    end

    Enum.each(open ++ Enum.drop(others, omitted), &print/1)
    0
  end

  # An item whose opening time cannot be read stays listed: its age is unknown.
  defp opened_before?(alert, cutoff) do
    case DateTime.from_iso8601(alert["first_seen_at"] || alert["timestamp"] || "") do
      {:ok, opened_at, _offset} -> DateTime.before?(opened_at, cutoff)
      {:error, _reason} -> false
    end
  end

  defp print(map), do: IO.write([Jason.encode!(map), "\n"])

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
