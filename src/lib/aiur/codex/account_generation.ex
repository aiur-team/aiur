defmodule Aiur.Codex.AccountGeneration do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration

  @account_updated "account/updated"
  @token_refresh "account/chatgptAuthTokens/refresh"

  @spec new_binding() :: reference()
  def new_binding, do: make_ref()

  @spec handle_notification(map(), String.t(), map()) :: :ignore | {:redacted, map()}
  def handle_notification(session, @account_updated, payload) when is_map(session) and is_map(payload) do
    if authenticated_account_update?(payload) do
      replace_account_binding(session)
    else
      lose_continuity(session)
    end

    {:redacted, redacted_message(@account_updated)}
  end

  def handle_notification(session, @token_refresh, payload) when is_map(session) and is_map(payload) do
    confirm_account_binding(session)
    {:redacted, redacted_message(@token_refresh)}
  end

  def handle_notification(_session, _method, _payload), do: :ignore

  @spec process_stopped(map()) :: :ok
  def process_stopped(session) when is_map(session) do
    lose_continuity(session)
    :ok
  end

  defp replace_account_binding(session) do
    with {:ok, server, binding} <- binding_context(session) do
      ProviderAccountGeneration.replace(server, :codex, :app_server, binding, source: :codex_app_server)
    end

    :ok
  end

  defp confirm_account_binding(session) do
    with {:ok, server, binding} <- binding_context(session) do
      ProviderAccountGeneration.confirm(server, :codex, :app_server, binding, source: :codex_app_server)
    end

    :ok
  end

  defp lose_continuity(session) do
    with {:ok, server, binding} <- binding_context(session) do
      ProviderAccountGeneration.invalidate(server, :codex, :app_server, binding,
        source: :codex_app_server,
        reason: :continuity_lost
      )
    end

    :ok
  end

  defp binding_context(session) do
    case Map.get(session, :account_generation_binding) do
      binding when is_reference(binding) -> {:ok, Map.get(session, :account_generation_server, ProviderAccountGeneration), binding}
      _ -> :error
    end
  end

  defp authenticated_account_update?(payload) do
    case get_in(payload, ["params", "authMode"]) do
      auth_mode when is_binary(auth_mode) -> String.trim(auth_mode) != ""
      _ -> false
    end
  end

  defp redacted_message(method), do: %{payload: %{"method" => method, "params" => %{}}, raw: nil}
end
