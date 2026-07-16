defmodule AiurWeb.FinancialDataAccess.Proof do
  @moduledoc false

  alias AiurWeb.Endpoint
  alias AiurWeb.FinancialDataAccess.{Context, Generation}

  @authentication_required {:error, :authentication_required}

  @spec configuration(keyword(), pos_integer()) ::
          {:ok, map()} | {:error, :authentication_required | :authentication_not_configured}
  def configuration(opts, version) do
    username = System.get_env("AIUR_DASHBOARD_USERNAME")
    password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    endpoint_config = Application.get_env(:aiur, Endpoint, [])
    required? = Keyword.get(opts, :required?, Keyword.get(endpoint_config, :dashboard_auth_required) == true)
    secret = Keyword.get(endpoint_config, :secret_key_base)

    cond do
      present?(username) and present?(password) and present?(secret) ->
        fingerprint = keyed_digest(secret, "financial-data-config", {version, username, password, required?})

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

  @spec new_session_marker(map(), pos_integer()) :: map()
  def new_session_marker(config, version) do
    connection_generation = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

    %{
      "version" => version,
      "configuration_generation" => config.generation,
      "connection_generation" => connection_generation,
      "proof" => access_proof(config.secret, config.generation, connection_generation, version)
    }
  end

  @spec context_from_session(map(), String.t(), pos_integer()) :: {:ok, Context.t()} | :error
  def context_from_session(session, session_key, version) when is_map(session) do
    with %{
           "version" => ^version,
           "configuration_generation" => configuration_generation,
           "connection_generation" => connection_generation,
           "proof" => proof
         } <- Map.get(session, session_key),
         true <- opaque_value?(configuration_generation),
         true <- opaque_value?(connection_generation),
         true <- opaque_value?(proof),
         {:ok, config} <- configuration([], version),
         true <- secure_equal?(configuration_generation, config.generation),
         expected_proof <- access_proof(config.secret, configuration_generation, connection_generation, version),
         true <- secure_equal?(proof, expected_proof) do
      {:ok,
       %Context{
         configuration_generation: configuration_generation,
         connection_generation: connection_generation,
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
         expected_proof <-
           access_proof(
             config.secret,
             context.configuration_generation,
             context.connection_generation,
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

  defp access_proof(secret, configuration_generation, connection_generation, version) do
    keyed_digest(
      secret,
      "financial-data-access",
      {version, configuration_generation, connection_generation}
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
end
