defmodule Aiur.AlertsCLI do
  @moduledoc false

  alias Aiur.AlertFeed

  @default_limit 100

  @usage "aiur: alerts accepts --needs-attention, --limit <n>, --all"

  @spec parse([String.t()]) :: {:ok, keyword()} | {:error, String.t()}
  def parse(argv), do: parse(argv, [])

  defp parse([], acc), do: {:ok, acc}
  defp parse(["--needs-attention" | rest], acc), do: parse(rest, [{:needs_attention, true} | acc])
  defp parse(["--all" | rest], acc), do: parse(rest, [{:limit, :all} | acc])

  defp parse(["--limit", n | rest], acc) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> parse(rest, [{:limit, i} | acc])
      _ -> {:error, "aiur: alerts --limit needs a positive integer"}
    end
  end

  defp parse(_, _), do: {:error, @usage}

  # Open attention items are never cut: only the other history rows are capped.
  @spec run(keyword()) :: 0 | 64
  def run(argv: argv) do
    case parse(argv) do
      {:ok, opts} -> run(opts)
      {:error, msg} ->
        IO.puts(:stderr, msg)
        64
    end
  end

  def run(opts) do
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
end
