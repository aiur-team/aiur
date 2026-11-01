defmodule AiurWeb.Build.Index.LastAgents do
  @moduledoc false

  @spec snapshot(map()) :: {:ok, map()} | {:error, :unavailable}
  def snapshot(%{index: {:ok, index}, parts: %{now: %{rows: rows, source: source}}}) when is_map(rows) and is_map(source) do
    rows = index.all |> Enum.filter(fn {_id, row} -> row.sec == "now" end) |> Enum.map(&elem(&1, 1))
    observed_at = source.observed_at

    if is_integer(observed_at) and source.state in ["ok", "stale"],
      do: {:ok, %{sections: %{now: rows}, sources: %{agents: source}, observed_at: observed_at}},
      else: {:error, :unavailable}
  end

  def snapshot(_state), do: {:error, :unavailable}
end
