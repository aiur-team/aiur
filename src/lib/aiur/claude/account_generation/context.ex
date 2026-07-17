defmodule Aiur.Claude.AccountGeneration.Context do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration.Context, as: SharedContext

  @spec new_binding(GenServer.server()) :: map()
  def new_binding(server),
    do: SharedContext.new_binding(:claude, :app_server, server)

  @spec fetch(map()) ::
          {:ok, GenServer.server(), reference(), reference(), String.t()} | :error
  def fetch(session), do: SharedContext.fetch(session)

  @spec auth_mode(map()) :: :subscription | :api_key | nil
  def auth_mode(session) do
    case SharedContext.value(session, :auth_mode) do
      auth_mode when auth_mode in [:subscription, :api_key] -> auth_mode
      _other -> nil
    end
  end

  @spec put_auth_mode(map(), :subscription | :api_key) :: :ok
  def put_auth_mode(session, auth_mode)
      when auth_mode in [:subscription, :api_key],
      do: SharedContext.put(session, :auth_mode, auth_mode)

  def put_auth_mode(_session, _auth_mode), do: :ok

  @spec clear_auth_mode(map()) :: :ok
  def clear_auth_mode(session),
    do: SharedContext.delete(session, :auth_mode)

  @spec clear(map()) :: :ok
  def clear(session),
    do: SharedContext.clear(:claude, :app_server, session)
end
