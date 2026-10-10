defmodule Aiur.AlertsCLI do
  @moduledoc false

  alias Aiur.AlertFeed

  @default_limit 100

  # Open attention items are never cut: only the other history rows are capped.
  @spec run(keyword()) :: :ok
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
  end
end
