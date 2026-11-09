defmodule AiurWeb.FinancialDataAccess.Proof do
  @moduledoc false

  alias AiurWeb.Endpoint
  alias AiurWeb.FinancialDataAccess.{Context, Generation}

  @authentication_required {:error, :authentication_required}

  @spec configuration(keyword(), pos_integer()) ::
          {:ok, map()} | {:error, :authentication_required | :authentication_not_configured}
  def configuration(opts, version) do
    {username, password} = credentials(opts)
    endpoint_config = Application.get_env(:aiur, Endpoint, [])
    enforced? = Keyword.get(endpoint_config, :dashboard_auth_required) == true
    required? = Keyword.get(opts, :required?, enforced?)
    secret = Keyword.get(endpoint_config, :secret_key_base)

    cond do
      present?(username) and present?(password) and present?(secret) ->
        # The fingerprint must track the deployed configuration — credentials
        # plus the endpoint's enforcement setting — and never a caller's
        # per-call `required?` override. Stream Deck token issuance always
        # passes `required?: true` while dashboard reads inherit the endpoint
        # setting, so folding the override in made two legitimate callers
        # disagree and rotate the shared generation against each other,
        # silently invalidating every outstanding Stream Deck token.
        fingerprint = keyed_digest(secret, "financial-data-config", {version, username, password, enforced?})

        case Generation.current(fingerprint) do
          {:ok, generation} ->
            {:ok,
             %{
               generation: generation,
               password: password,
               required?: required?,
               secret: secret,
               username: username
             }}

          :error ->
            @authentication_required
        end

      required? ->
        :ok = Generation.invalidate()
        {:error, :authentication_required}

      true ->
        :ok = Generation.invalidate()
        {:error, :authentication_not_configured}
    end
  end

  # Plug callers may carry credentials established by an earlier trusted plug
  # in `conn.private`. That keeps the authentication boundary testable without
  # changing the process-global operator environment; ordinary router requests
  # continue to read the operator-provided environment variables.
  defp credentials(opts) do
    case Keyword.fetch(opts, :credentials) do
      {:ok, {username, password}} -> {username, password}
      {:ok, nil} -> {nil, nil}
      {:ok, _invalid} -> {nil, nil}
      :error -> {System.get_env("AIUR_DASHBOARD_USERNAME"), System.get_env("AIUR_DASHBOARD_PASSWORD")}
    end
  end

  @spec new_session_marker(map(), pos_integer(), integer()) :: map()
  def new_session_marker(config, version, issued_at \\ System.system_time(:second)) do
    connection_generation = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

    %{
      "version" => version,
      "configuration_generation" => config.generation,
      "connection_generation" => connection_generation,
      "issued_at" => issued_at,
      "proof" => access_proof(config.secret, config.generation, connection_generation, issued_at, version)
    }
  end

  @spec context_from_session(map(), String.t(), pos_integer()) :: {:ok, Context.t()} | :error
  def context_from_session(session, session_key, version) when is_map(session) do
    with %{
           "version" => ^version,
           "configuration_generation" => configuration_generation,
           "connection_generation" => connection_generation,
           "issued_at" => issued_at,
           "proof" => proof
         } <- Map.get(session, session_key),
         true <- opaque_value?(configuration_generation),
         true <- opaque_value?(connection_generation),
         true <- valid_issued_at?(issued_at),
         true <- opaque_value?(proof),
         {:ok, config} <- configuration([], version),
         true <- secure_equal?(configuration_generation, config.generation),
         true <- not expired?(issued_at),
         expected_proof <- access_proof(config.secret, configuration_generation, connection_generation, issued_at, version),
         true <- secure_equal?(proof, expected_proof) do
      {:ok,
       %Context{
         configuration_generation: configuration_generation,
         connection_generation: connection_generation,
         issued_at: issued_at,
         proof: proof
       }}
    else
      _other -> :error
    end
  end

  def context_from_session(_session, _session_key, _version), do: :error

  @spec identity(Context.t() | nil, pos_integer()) ::
          {:ok, {String.t(), String.t()}} | {:error, :authentication_required}
  def identity(%Context{} = context, version) do
    with {:ok, config} <- configuration([], version),
         true <- secure_equal?(context.configuration_generation, config.generation),
         true <- not expired?(context.issued_at),
         expected_proof <-
           access_proof(
             config.secret,
             context.configuration_generation,
             context.connection_generation,
             context.issued_at,
             version
           ),
         true <- secure_equal?(context.proof, expected_proof) do
      {:ok, {context.configuration_generation, context.connection_generation}}
    else
      _other -> @authentication_required
    end
  end

  def identity(_context, version) do
    _ = current_configuration_generation(version)
    @authentication_required
  end

  @spec current_configuration_generation(pos_integer()) ::
          {:ok, String.t()} | {:error, :authentication_required}
  def current_configuration_generation(version) do
    case configuration([], version) do
      {:ok, config} -> {:ok, config.generation}
      _error -> @authentication_required
    end
  end

  defp access_proof(secret, configuration_generation, connection_generation, issued_at, version) do
    keyed_digest(
      secret,
      "financial-data-access",
      {version, configuration_generation, connection_generation, issued_at}
    )
  end

  defp keyed_digest(secret, domain, value) do
    :crypto.mac(:hmac, :sha256, secret, [domain, 0, :erlang.term_to_binary(value)])
    |> Base.url_encode64(padding: false)
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp opaque_value?(value), do: is_binary(value) and byte_size(value) in 32..128
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_issued_at?(issued_at), do: is_integer(issued_at) and issued_at <= System.system_time(:second)

  defp expired?(issued_at) do
    max_age = Aiur.Config.settings!().dashboard_auth.session_max_age_days * 86_400
    System.system_time(:second) - issued_at > max_age
  end
end
