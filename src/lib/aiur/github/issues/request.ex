defmodule Aiur.GitHub.Issues.Request do
  @moduledoc false

  alias Aiur.GitHub.Access

  # Worst-case JSON escaping is 6 bytes per character: 65,536 × 6 + 128 KiB metadata.
  @max_issue_response_bytes 524_288
  @spec max_issue_response_bytes() :: pos_integer()
  def max_issue_response_bytes, do: @max_issue_response_bytes

  # The response cap is the endpoint's, not the caller's. Without it here the poll
  # could deposit an issue larger than `fetch_issue_raw_conditional/2` is willing
  # to accept, and the detail path would then be served — from the shared entry —
  # a body it would have rejected had it fetched the same URL itself.
  @spec conditional_get(map(), String.t(), term(), pos_integer()) :: tuple()
  def conditional_get(ctx, url, etag, max_response_bytes \\ @max_issue_response_bytes) do
    request = %{method: :get, url: url, token: ctx.token, max_response_bytes: max_response_bytes, caller: Map.get(ctx, :caller, "open_issue_list_conditional")}
    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request

    case ctx.request_fun.(request) do
      {:ok, %{status: 200} = response} ->
        conditional_ok_response(response, etag, max_response_bytes)

      {:ok, %{status: 304} = response} ->
        retained_etag = Access.header(Map.get(response, :headers, []), "etag") || etag
        {:not_modified, retained_etag}

      {:ok, %{status: _status} = response} ->
        {:http_error, response}

      {:error, reason} ->
        {:error, Access.classify_error({:error, reason})}
    end
  end

  # The bounded collector halts an over-limit body and hands back a 200 with an
  # empty body (`Transport.OffProcess.bounded_response_collector/1`). Left unrecognised,
  # that fell through the list-page match to `Access.github_status_error/1` and
  # surfaced as `{:github, :http, %{status: 200}}` — a "failure" carrying a
  # success status, which hid the real cause for a spec-heavy backlog (#2533).
  # Name it instead, before the ordinary 200 path claims it.
  defp conditional_ok_response(%{private: %{aiur_response_too_large: true}}, _etag, max_response_bytes) do
    {:error, {:github, :http, %{status: 200, reason: :response_too_large, max_response_bytes: max_response_bytes}}}
  end

  defp conditional_ok_response(%{body: body} = response, etag, _max_response_bytes) do
    retained_etag = Access.header(Map.get(response, :headers, []), "etag") || etag
    {:ok, body, retained_etag, response}
  end

  # A 200 without a body key never reached the list-page match before either;
  # keep routing it to the generic status path rather than raising here.
  defp conditional_ok_response(response, _etag, _max_response_bytes), do: {:http_error, response}
  @spec response_header(term(), String.t()) :: String.t() | nil
  def response_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: header_value(value)

      _ ->
        nil
    end)
  end

  def response_header(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: header_value(value)
    end)
  end

  def response_header(_headers, _name), do: nil

  defp header_value([value | _]), do: header_value(value)
  defp header_value(value) when is_binary(value), do: value
  defp header_value(_value), do: nil
end
