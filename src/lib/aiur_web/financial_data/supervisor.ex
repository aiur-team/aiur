defmodule AiurWeb.FinancialData.Supervisor do
  @moduledoc false

  use Supervisor

  alias AiurWeb.FinancialData
  alias AiurWeb.FinancialData.{ChangeBridge, SubscriptionAuthority}
  alias AiurWeb.FinancialDataAccess.Generation
  alias AiurWeb.VoiceSessionLimiter

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [Generation, SubscriptionAuthority, FinancialData, ChangeBridge, VoiceSessionLimiter]
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
