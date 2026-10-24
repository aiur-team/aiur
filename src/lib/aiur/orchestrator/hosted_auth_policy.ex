defmodule Aiur.Orchestrator.HostedAuthPolicy do
  @moduledoc "Fail-closed authentication decisions for hosted execution."

  @type auth_class :: :api_key | :subscription | :oauth | :personal_token | :headers | :agent_identity | :bedrock | :unknown
  @type refusal :: {:unsafe_hosted_authentication, String.t(), auth_class()}

  @api_key_modes MapSet.new(["api_key", "apikey"])

  @doc "Authorize one normalized provider authentication observation."
  @spec authorize(String.t(), String.t(), term()) :: :ok | {:error, refusal()}
  def authorize("hosted", _provider, :api_key), do: :ok

  def authorize("hosted", provider, auth_class) when is_binary(provider),
    do: {:error, {:unsafe_hosted_authentication, provider, normalize(auth_class)}}

  def authorize(_mode, _provider, _auth_class), do: :ok

  @doc "Extract the safe hosted-auth refusal from a startup or turn error."
  @spec refusal(term()) :: {:ok, refusal()} | :error
  def refusal({:unsafe_hosted_authentication, provider, auth_class} = refusal)
      when is_binary(provider) and auth_class in [:api_key, :subscription, :oauth, :personal_token, :headers, :agent_identity, :bedrock, :unknown],
      do: {:ok, refusal}

  def refusal({:turn_unretryable, reason}), do: refusal(reason)
  def refusal(_reason), do: :error

  @doc "Whether a registry entry proves every supported account mode is API-key based."
  @spec api_key_only_fallback?(map()) :: boolean()
  def api_key_only_fallback?(entry) when is_map(entry) do
    modes = get_in(entry, [:account_generation, :auth_modes])

    get_in(entry, [:accounts, :kind]) == :api_key and
      is_list(modes) and
      modes != [] and
      Enum.all?(modes, &MapSet.member?(@api_key_modes, &1))
  end

  def api_key_only_fallback?(_entry), do: false

  defp normalize(auth_class)
       when auth_class in [:api_key, :subscription, :oauth, :personal_token, :headers, :agent_identity, :bedrock, :unknown],
       do: auth_class

  defp normalize(_auth_class), do: :unknown
end
