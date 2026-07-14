defmodule Aiur.Codex.AccountGeneration do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration

  @account_updated "account/updated"
  @token_refresh "account/chatgptAuthTokens/refresh"
  @rate_limits_updated "account/rateLimits/updated"

  @account_updated_auth_modes ~w(apikey chatgpt chatgptAuthTokens headers agentIdentity personalAccessToken bedrockApiKey)

  @type binding_context :: %{
          binding: reference(),
          authority: reference(),
          context: reference(),
          topic: String.t()
        }

  @spec new_binding(GenServer.server()) :: binding_context()
  def new_binding(server \\ ProviderAccountGeneration) do
    binding =
      case ProviderAccountGeneration.issue_binding(server, :codex, :app_server) do
        {:ok, binding} -> binding
        {:error, _reason} -> %{binding: make_ref(), authority: make_ref(), topic: mint_topic()}
      end

    context = make_ref()
    Process.put(context_key(context), binding)
    Map.put(binding, :context, context)
  end

  @spec handle_notification(map(), String.t(), map()) :: :ignore | {:redacted, map()}
  def handle_notification(session, @account_updated, payload) when is_map(session) and is_map(payload) do
    case account_updated_auth_mode(payload) do
      {:ok, auth_mode} -> bind_account(session, auth_mode)
      :logout -> lose_continuity(session, :logout)
      :error -> lose_continuity(session, :unsupported_auth_mode)
    end

    {:redacted, redacted_message(@account_updated)}
  end

  def handle_notification(session, @token_refresh, payload) when is_map(session) and is_map(payload) do
    confirm_account_binding(session)
    {:redacted, redacted_message(@token_refresh)}
  end

  def handle_notification(_session, @rate_limits_updated, _payload),
    do: {:redacted, redacted_message(@rate_limits_updated)}

  def handle_notification(session, <<"account/", _rest::binary>> = method, _payload) when is_map(session) do
    lose_continuity(session, :untrusted_lifecycle)
    {:redacted, redacted_message(method)}
  end

  def handle_notification(_session, _method, _payload), do: :ignore

  @doc "Seeds the binding from Handshake's privacy-reduced account/read result."
  @spec seed_from_account_read(map(), map()) :: :ok
  def seed_from_account_read(session, %{auth_mode: auth_mode}) when auth_mode in @account_updated_auth_modes do
    bind_account(session, auth_mode)
    :ok
  end

  def seed_from_account_read(session, _response) when is_map(session) do
    lose_continuity(session, :no_authenticated_account)
    :ok
  end

  def seed_from_account_read(_session, _response), do: :ok

  @spec process_stopped(map()) :: :ok
  def process_stopped(session) when is_map(session) do
    lose_continuity(session, :continuity_lost)
    clear_binding_context(session)
    :ok
  end

  defp bind_account(session, auth_mode) do
    with_recovered_binding(session, fn server, binding, authority ->
      ProviderAccountGeneration.bind(server, :codex, :app_server, binding,
        source: :codex_app_server,
        auth_mode: auth_mode,
        authority: authority
      )
    end)
  end

  defp confirm_account_binding(session) do
    with_recovered_binding(session, fn server, binding, authority ->
      ProviderAccountGeneration.confirm(server, :codex, :app_server, binding,
        source: :codex_app_server,
        authority: authority
      )
    end)
  end

  defp lose_continuity(session, reason) do
    with_recovered_binding(session, fn server, binding, authority ->
      ProviderAccountGeneration.invalidate(server, :codex, :app_server, binding,
        source: :codex_app_server,
        reason: reason,
        authority: authority
      )
    end)
  end

  defp with_recovered_binding(session, transition) when is_function(transition, 3) do
    with {:ok, server, binding, authority, topic} <- binding_context(session),
         :ok <- recover_retained_binding(server, binding, authority, topic) do
      transition.(server, binding, authority)
    end

    :ok
  end

  defp recover_retained_binding(server, binding, authority, topic) when is_binary(topic) do
    ProviderAccountGeneration.recover_binding(server, :codex, :app_server, %{
      binding: binding,
      authority: authority,
      topic: topic
    })
  end

  defp recover_retained_binding(_server, _binding, _authority, _topic), do: :ok

  defp binding_context(session) do
    case Map.fetch(session, :account_generation_context) do
      {:ok, context} when is_reference(context) ->
        case current_binding_context(context) do
          {:ok, _binding} = binding -> binding_context_from(binding, session)
          :cleared -> :error
          :error -> fallback_binding_context(session)
        end

      _ ->
        fallback_binding_context(session)
    end
  end

  defp fallback_binding_context(session) do
    binding_context_from(
      %{
        binding: Map.get(session, :account_generation_binding),
        authority: Map.get(session, :account_generation_authority),
        topic: Map.get(session, :account_generation_topic)
      },
      session
    )
  end

  defp binding_context_from({:ok, binding}, session), do: binding_context_from(binding, session)

  defp binding_context_from(:error, _session), do: :error

  defp binding_context_from(%{binding: binding, authority: authority} = context, session) do
    case {binding, authority} do
      {binding, authority} when is_reference(binding) and is_reference(authority) ->
        server = Map.get(session, :account_generation_server, ProviderAccountGeneration)
        topic = Map.get(context, :topic)
        {:ok, server, binding, authority, topic}

      _ ->
        :error
    end
  end

  defp current_binding_context(context) do
    case Process.get(context_key(context)) do
      %{binding: binding, authority: authority, topic: topic}
      when is_reference(binding) and is_reference(authority) and is_binary(topic) ->
        {:ok, %{binding: binding, authority: authority, topic: topic}}

      :cleared ->
        :cleared

      _ ->
        :error
    end
  end

  defp clear_binding_context(%{account_generation_context: context}) when is_reference(context),
    do: Process.put(context_key(context), :cleared)

  defp clear_binding_context(_session), do: :ok

  defp context_key(context), do: {__MODULE__, :binding_context, context}

  defp mint_topic, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp account_updated_auth_mode(%{"params" => %{"authMode" => nil}}), do: :logout

  defp account_updated_auth_mode(%{"params" => %{"authMode" => auth_mode}}) when auth_mode in @account_updated_auth_modes,
    do: {:ok, auth_mode}

  defp account_updated_auth_mode(_payload), do: :error

  defp redacted_message(method), do: %{payload: %{"method" => method, "params" => %{}}, raw: nil}
end
