defmodule AiurWeb.OperatorControlCenter.RedactedMeterSource do
  @moduledoc "Redacted provider observations for authenticated device read models."
  alias Aiur.{CodingAgent, ProviderMeterProjection}

  @spec load(term(), keyword()) :: map()
  def load(_context, _opts) do
    Map.new(CodingAgent.provider_families(), &{&1, ProviderMeterProjection.redacted_snapshot(&1)})
  end
end
