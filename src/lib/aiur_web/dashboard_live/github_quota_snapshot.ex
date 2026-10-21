defmodule AiurWeb.DashboardLive.GitHubQuotaSnapshot do
  @moduledoc false

  alias Aiur.GitHub.Quota

  @spec read() :: map()
  def read do
    case Quota.cached_snapshot(Quota, 24 * 60 * 60_000) do
      {:ok, snapshot, age_ms, observed_at_ms} ->
        stale(snapshot, age_ms, observed_at_ms)

      :miss ->
        try do
          Quota.snapshot!(Quota, 1_000)
        catch
          :exit, _reason -> %{state: :unknown, windows: %{}, backoffs: []}
        end
    end
  end

  defp stale(snapshot, age_ms, observed_at_ms) do
    observed_at = DateTime.from_unix!(observed_at_ms, :millisecond)

    snapshot
    |> Map.put(:windows, Map.new(snapshot.windows, fn {resource, window} -> {resource, Map.put(window, :snapshot_stale?, true) |> Map.put(:observed_at, observed_at)} end))
    |> Map.put(:snapshot_age_ms, age_ms)
  end
end
