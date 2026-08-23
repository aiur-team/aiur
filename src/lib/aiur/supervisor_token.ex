defmodule Aiur.SupervisorToken do
  @moduledoc """
  Classifies the bearer credential used by the Supervisor Decision API.

  Missing or blank credentials keep the optional API disabled, matching how the
  rest of the codebase treats an empty environment value (see `Aiur.Env.set?/2`
  and the dotenv readers). Values that are present and non-blank but unusable
  are invalid startup configuration.
  """

  @minimum_token_bytes 32
  @bearer_token ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/

  @type classification :: :missing | :invalid | {:ok, String.t()}

  @doc "Classifies a configured supervisor token without exposing its value."
  @spec classify(term()) :: classification()
  def classify(nil), do: :missing

  def classify(token) when is_binary(token) do
    cond do
      String.trim(token) == "" -> :missing
      valid?(token) -> {:ok, token}
      true -> :invalid
    end
  end

  def classify(_other), do: :invalid

  defp valid?(token) do
    byte_size(token) >= @minimum_token_bytes and token == String.trim(token) and
      Regex.match?(@bearer_token, token)
  end
end
