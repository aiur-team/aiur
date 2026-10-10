defmodule Aiur.AlertsCLI do
  @moduledoc false

  alias Aiur.AlertFeed

  @limit 100

  @spec run(keyword()) :: :ok
  def run(opts) do
    alerts = AlertFeed.list(opts)
    count = length(alerts)

    if count > @limit do
      IO.puts(:stderr, "aiur: showing latest #{@limit} of #{count} matching retained alerts; older matches omitted")
    end

    alerts
    |> Enum.take(-@limit)
    |> Enum.map(&[Jason.encode!(&1), "\n"])
    |> IO.write()
  end
end
