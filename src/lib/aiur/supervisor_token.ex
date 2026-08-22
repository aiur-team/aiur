defmodule Aiur.SupervisorToken do
  @moduledoc """
  Classifies the bearer credential used by the Supervisor Decision API.

  Missing credentials keep the optional API disabled. Values that are present
  but unusable are invalid startup configuration.
  """

  @minimum_token_bytes 32
  @bearer_token ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/

  @type classification :: :missing | :invalid | {:ok, String.t()}

  @doc "Classifies a configured supervisor token without exposing its value."
  @spec classify(term()) :: classification()
  def classify(nil), do: :missing

  def classify(token) when is_binary(token) do
    if valid?(token), do: {:ok, token}, else: :invalid
  end

  def classify(_other), do: :invalid

  defp valid?(token) do
    byte_size(token) >= @minimum_token_bytes and token == String.trim(token) and
      Regex.match?(@bearer_token, token)
  end
end
