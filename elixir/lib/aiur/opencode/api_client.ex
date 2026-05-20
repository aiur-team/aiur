defmodule Aiur.Opencode.ApiClient do
  @moduledoc false

  require Logger

  @receive_timeout 30_000

  @spec create_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_session(base_url, title), do: request(:post, base_url, "/session", json: %{title: title})

  @spec post_message(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def post_message(base_url, session_id, payload),
    do: request(:post, base_url, "/session/#{session_id}/message", json: payload)

  @spec show_toast(String.t(), String.t(), String.t(), String.t() | atom()) :: {:ok, map()} | {:error, term()}
  def show_toast(base_url, title, message, variant),
    do: request(:post, base_url, "/toast", json: %{title: title, message: message, variant: to_string(variant)})

  @spec abort_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def abort_session(base_url, session_id), do: request(:post, base_url, "/session/#{session_id}/abort", json: %{})

  @spec health(String.t()) :: {:ok, map()} | {:error, term()}
  def health(base_url), do: request(:get, base_url, "/global/health")

  defp request(method, base_url, path, opts \\ []) do
    req = Req.new(base_url: base_url, retry: false, receive_timeout: @receive_timeout)

    case Req.request(req, Keyword.merge(opts, method: method, url: path)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        Logger.info("opencode_http method=#{method} path=#{path} status=#{status}")
        {:ok, normalize_body(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("opencode_http method=#{method} path=#{path} status=#{status} body=#{inspect(truncate(body))}")
        {:error, {:opencode_http, status, normalize_body(body)}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(body) when is_binary(body), do: Jason.decode!(body)
  defp normalize_body(nil), do: %{}
  defp normalize_body(body), do: %{"body" => body}

  defp truncate(body) when is_binary(body) and byte_size(body) > 2_048,
    do: binary_part(body, 0, 2_048) <> "..."

  defp truncate(body), do: body
end
