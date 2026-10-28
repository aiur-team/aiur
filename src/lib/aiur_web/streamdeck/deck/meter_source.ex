defmodule AiurWeb.Streamdeck.Deck.MeterSource do
  @moduledoc "Redacted provider observations for the token-authenticated deck."
  alias Aiur.{CodingAgent, ProviderMeterProjection}

  @spec load(term(), keyword()) :: map()
  def load(_context, _opts) do
    Map.new(CodingAgent.provider_families(), &{&1, ProviderMeterProjection.redacted_snapshot(&1)})
  end
end
