defmodule Aiur.EpicConfirmationCLI do
  @moduledoc false

  @spec result(map(), map()) :: map()
  def result(result, provenance) do
    rows =
      Enum.map(result.results, fn row ->
        Map.update!(row, :status, &if(&1 == :changed, do: :confirmed, else: &1))
      end)

    result |> Map.put(:results, rows) |> Map.put(:source, provenance.source) |> Map.put(:command, "epic confirm")
  end

  @spec refusal(list()) :: map()
  def refusal(failures), do: %{ok: false, refused: Enum.map(failures, &failure/1)}
  defp failure({:no_override, n}), do: %{number: n, reason: :no_override}
  defp failure({:epic_changed, n, epic}), do: %{number: n, reason: :epic_changed, current: epic}
  defp failure({:not_a_configured_epic, n, epic}), do: %{number: n, reason: :not_a_configured_epic, current: epic}

  @spec error(list()) :: String.t()
  def error(failures), do: "refused, nothing written: " <> Enum.map_join(failures, "; ", &failure_text/1)
  defp failure_text({:no_override, n}), do: "##{n} has no override"
  defp failure_text({:epic_changed, n, epic}), do: "##{n} is now #{epic} (expected epic changed)"
  defp failure_text({:not_a_configured_epic, n, epic}), do: "##{n} epic #{epic} is not configured"

  @spec render(map()) :: String.t()
  def render(result) do
    Enum.map_join(result.results, "\n", fn
      %{number: n, status: :confirmed, epic: epic, previous: p} -> "confirmed #{epic}: ##{n} (was #{p.source})"
      %{number: n, epic: epic} -> "#{epic}: ##{n} unchanged (already confirmed)"
    end)
  end
end
