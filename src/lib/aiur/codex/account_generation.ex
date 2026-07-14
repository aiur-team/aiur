defmodule Aiur.Codex.AccountGeneration do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration

  @account_updated "account/updated"
  @token_refresh "account/chatgptAuthTokens/refresh"

  @account_read_auth_modes %{
    "amazonBedrock" => "bedrockApiKey",
    "apiKey" => "apikey",
    "chatgpt" => "chatgpt"
  }

  @account_updated_auth_modes ~w(apikey chatgpt chatgptAuthTokens headers agentIdentity personalAccessToken bedrockApiKey)

  @spec new_binding() :: reference()
  def new_binding, do: make_ref()

  @spec handle_notification(map(), String.t(), map()) :: :ignore | {:redacted, map()}
  def handle_notification(session, @account_updated, payload) when is_map(session) and is_map(payload) do
    case account_updated_auth_mode(payload) do
      {:ok, auth_mode} -> bind_account(session, auth_mode)
      :error -> lose_continuity(session, :unsupported_auth_mode)
    end

    {:redacted, redacted_message(@account_updated)}
  end

  def handle_notification(session, @token_refresh, payload) when is_map(session) and is_map(payload) do
    confirm_account_binding(session)
    {:redacted, redacted_message(@token_refresh)}
  end

  def handle_notification(_session, _method, _payload), do: :ignore

  @doc "Seeds the binding from the trusted account/read response without retaining it."
  @spec seed_from_account_read(map(), map()) :: :ok
  def seed_from_account_read(session, response) when is_map(session) and is_map(response) do
    case account_read_auth_mode(response) do
      {:ok, auth_mode} -> bind_account(session, auth_mode)
      :error -> lose_continuity(session, :no_authenticated_account)
    end

    :ok
  end

  def seed_from_account_read(_session, _response), do: :ok

  @spec process_stopped(map()) :: :ok
  def process_stopped(session) when is_map(session) do
    lose_continuity(session, :continuity_lost)
    :ok
  end

  defp bind_account(session, auth_mode) do
    with {:ok, server, binding} <- binding_context(session) do
      ProviderAccountGeneration.bind(server, :codex, :app_server, binding,
        source: :codex_app_server,
        auth_mode: auth_mode
      )
    end

    :ok
  end

  defp confirm_account_binding(session) do
    with {:ok, server, binding} <- binding_context(session) do
      ProviderAccountGeneration.confirm(server, :codex, :app_server, binding, source: :codex_app_server)
    end

    :ok
  end

  defp lose_continuity(session, reason) do
    with {:ok, server, binding} <- binding_context(session) do
      ProviderAccountGeneration.invalidate(server, :codex, :app_server, binding,
        source: :codex_app_server,
        reason: reason
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

  defp account_updated_auth_mode(%{"params" => %{"authMode" => auth_mode}}) when auth_mode in @account_updated_auth_modes,
    do: {:ok, auth_mode}

  defp account_updated_auth_mode(_payload), do: :error

  defp account_read_auth_mode(%{"account" => %{"type" => type}}) do
    case Map.fetch(@account_read_auth_modes, type) do
      {:ok, auth_mode} -> {:ok, auth_mode}
      :error -> :error
    end
  end

  defp account_read_auth_mode(_response), do: :error

  defp redacted_message(method), do: %{payload: %{"method" => method, "params" => %{}}, raw: nil}
end
