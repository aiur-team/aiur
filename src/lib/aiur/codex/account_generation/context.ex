defmodule Aiur.Codex.AccountGeneration.Context do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration.Context, as: SharedContext

  @spec new_binding(GenServer.server()) :: map()
  def new_binding(server),
    do: SharedContext.new_binding(:codex, :app_server, server)

  @spec fetch(map()) ::
          {:ok, GenServer.server(), reference(), reference(), String.t()} | :error
  def fetch(session), do: SharedContext.fetch(session)

  @spec clear(map()) :: :ok
  def clear(session),
    do: SharedContext.clear(:codex, :app_server, session)

  @spec put_auth_mode(map(), String.t()) :: :ok
  def put_auth_mode(session, auth_mode) when is_binary(auth_mode),
    do: SharedContext.put(session, :auth_mode, auth_mode)

  def put_auth_mode(_session, _auth_mode), do: :ok

  @spec auth_mode(map()) :: String.t() | nil
  def auth_mode(session) do
    case SharedContext.value(session, :auth_mode) do
      auth_mode when is_binary(auth_mode) -> auth_mode
      _other -> nil
    end
  end

  @spec clear_auth_mode(map()) :: :ok
  def clear_auth_mode(session),
    do: SharedContext.delete(session, :auth_mode)

  @spec put_rate_limit_ids(map(), [String.t()]) :: :ok
  def put_rate_limit_ids(session, ids) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1),
      do: SharedContext.put(session, :rate_limit_ids, ids),
      else: :ok
  end

  def put_rate_limit_ids(_session, _ids), do: :ok

  @spec single_rate_limit_id(map()) :: String.t() | nil
  def single_rate_limit_id(session) do
    case SharedContext.value(session, :rate_limit_ids) do
      [limit_id] when is_binary(limit_id) -> limit_id
      _other -> nil
    end
  end

  @spec clear_rate_limit_ids(map()) :: :ok
  def clear_rate_limit_ids(session),
    do: SharedContext.delete(session, :rate_limit_ids)
end
