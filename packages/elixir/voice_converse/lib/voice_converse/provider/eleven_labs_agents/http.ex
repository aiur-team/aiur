defmodule VoiceConverse.Provider.ElevenLabsAgents.HTTP do
  @moduledoc false

  @spec get(String.t(), keyword()) :: {:ok, non_neg_integer(), binary()} | {:error, term()}
  def get(url, opts) do
    :inets.start()

    headers =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

    timeout = Keyword.get(opts, :receive_timeout, 5_000)

    case :httpc.request(:get, {String.to_charlist(url), headers}, request_options(timeout), body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec request_options(non_neg_integer()) :: keyword()
  def request_options(timeout) do
    [
      connect_timeout: timeout,
      timeout: timeout,
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end
end
