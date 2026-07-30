defmodule AiurWeb.StreamdeckAuth do
  @moduledoc false

  alias AiurWeb.Endpoint
  alias AiurWeb.FinancialDataAccess.Proof

  @access_version 1
  @token_salt "streamdeck-v1"
  @token_max_age 300

  @spec issue_token() :: {:ok, String.t()} | {:error, :authentication_required}
  def issue_token do
    case Proof.configuration([required?: true], @access_version) do
      {:ok, config} ->
        expires_at_ms = System.system_time(:millisecond) + @token_max_age * 1_000
        {:ok, Phoenix.Token.sign(Endpoint, @token_salt, %{generation: config.generation, expires_at_ms: expires_at_ms})}

      _ ->
        {:error, :authentication_required}
    end
  end

  @spec verify_token(term()) :: {:ok, String.t(), pos_integer()} | :error
  def verify_token(token) when is_binary(token) do
    with {:ok, %{generation: token_generation, expires_at_ms: expires_at_ms}} <- Phoenix.Token.verify(Endpoint, @token_salt, token, max_age: @token_max_age),
         true <- is_integer(expires_at_ms) and expires_at_ms > System.system_time(:millisecond),
         {:ok, current_config} <- Proof.configuration([required?: true], @access_version),
         current_generation <- current_config.generation,
         true <- secure_equal?(token_generation, current_generation) do
      {:ok, current_generation, expires_at_ms}
    else
      _ -> :error
    end
  end

  def verify_token(_token), do: :error

  @doc false
  @spec token_max_age_seconds() :: pos_integer()
  def token_max_age_seconds, do: @token_max_age

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false
end
