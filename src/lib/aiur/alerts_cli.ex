defmodule Aiur.AlertsCLI do
  @moduledoc false

  alias Aiur.AlertFeed

  @limit 100

  @spec run(keyword()) :: :ok
  def run(opts) do
    alerts = AlertFeed.list(opts)
    count = length(alerts)

    if count > @limit do
      IO.puts(
        Jason.encode!(%{
          "event" => "alert_feed_truncated",
          "limit" => @limit,
          "matching_count" => count,
          "message" => "Showing latest #{@limit} matching retained alerts; older matches omitted"
        })
      )
    end

    alerts
    |> Enum.take(-@limit)
    |> Enum.map(&[Jason.encode!(&1), "\n"])
    |> IO.write()
  end
end
