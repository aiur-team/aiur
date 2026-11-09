defmodule AiurPushRelay.Provider do
  @moduledoc "Provider boundary. The envelope contains only the configured fallback pin."
  @callback deliver(map(), map()) ::
              :ok | {:gone, term()} | {:retry, non_neg_integer()} | {:error, term()}
end

defmodule AiurPushRelay.Provider.Disabled do
  @moduledoc "Safe default until a real provider adapter is configured."
  @behaviour AiurPushRelay.Provider
  @impl true
  def deliver(_, _), do: {:error, :provider_not_configured}
end
