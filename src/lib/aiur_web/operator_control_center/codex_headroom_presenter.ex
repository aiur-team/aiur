defmodule AiurWeb.OperatorControlCenter.CodexHeadroomPresenter do
  @moduledoc "Adds the dispatch ranker's Codex headroom (the value `aiur agents` prints) to the Models panel view."

  alias Aiur.Accounts
  alias Aiur.Accounts.UsageReadings
  alias Aiur.CodingAgent.HeadroomDispatch
  alias AiurWeb.OperatorControlCenter.ProviderMetersPresenter

  @spec provider_meters_view(term(), map(), keyword()) :: map()
  def provider_meters_view(capability, snapshots, opts \\ []) do
    names =
      case Accounts.configured_names() do
        [] -> ["default"]
        names -> names
      end

    ProviderMetersPresenter.present(capability, snapshots, UsageReadings.snapshot("claude", names))
    |> attach(HeadroomDispatch.backend_reading("codex", opts))
  end

  @spec attach(map(), map() | nil) :: map()
  def attach(%{state: :authorized, cards: cards} = view, reading) when is_list(cards) do
    Map.put(view, :cards, Enum.map(cards, &attach_card(&1, reading)))
  end

  def attach(view, _reading), do: view

  defp attach_card(%{provider: :codex} = card, reading), do: Map.put(card, :headroom, present(reading))
  defp attach_card(card, _reading), do: card

  defp present(nil), do: %{status: :unknown, reason: "No headroom reading is available", age_seconds: nil}

  defp present(%{stale: true} = reading) do
    %{status: :stale, reason: "Last headroom reading is stale", age_seconds: Map.get(reading, :age_seconds)}
  end

  defp present(reading) do
    case HeadroomDispatch.remaining_percent(reading) do
      percent when is_integer(percent) -> %{status: :observed, remaining_percent: percent, age_seconds: Map.get(reading, :age_seconds)}
      _unknown -> %{status: :unknown, reason: "Headroom window is not available", age_seconds: Map.get(reading, :age_seconds)}
    end
  end
end
