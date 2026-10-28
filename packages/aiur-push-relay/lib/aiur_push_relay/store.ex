defmodule AiurPushRelay.Store do
  @moduledoc "Persistent handle registry and atomic send reservations; timestamps are relay seconds."
  @callback create(GenServer.server(), map()) :: :ok | {:error, term()}
  @callback get(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback delete(GenServer.server(), String.t()) :: :ok | {:error, term()}
  @callback reserve(GenServer.server(), map(), map(), integer()) ::
              :new | {:duplicate, integer()} | {:error, term()}
  @callback finish(GenServer.server(), String.t(), String.t(), atom()) :: :ok | {:error, term()}
  @callback release(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback health(GenServer.server()) :: :ok | {:error, term()}

  def call({module, server}, operation, args \\ []) do
    apply(module, operation, [server | args])
  catch
    :exit, _ -> {:error, :store_unavailable}
  end
end
