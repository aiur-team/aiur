defmodule Aiur.ProviderMeterProjection.SharedRefresh do
  @moduledoc false

  alias Aiur.CodingAgent
  alias Aiur.Instance.LeaseStore

  @spec fetch() :: map()
  def fetch do
    Map.new(CodingAgent.provider_families(), fn provider ->
      {provider, LeaseStore.shared_provider_meter(provider)}
    end)
  rescue
    _unavailable -> %{}
  catch
    :exit, _reason -> %{}
  end
end
