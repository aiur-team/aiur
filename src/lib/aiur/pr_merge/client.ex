defmodule Aiur.PrMerge.Client do
  @moduledoc "Operator-only transport: the credential is held by the standalone process."

  @spec request(String.t(), String.t(), String.t(), map() | nil) :: {:ok, term()} | {:error, String.t()}
  @spec request(String.t(), String.t(), String.t(), map() | nil, (keyword() -> term())) :: {:ok, term()} | {:error, String.t()}
  def request(token, method, path, body \\ nil, transport \\ &Req.request/1) do
    opts = [url: "https://api.github.com/" <> path, method: %{"get" => :get, "post" => :post, "put" => :put}[method], headers: headers(token), retry: false, receive_timeout: 30_000]
    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case transport.(opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: %{"message" => message}}} -> {:error, "GitHub #{status}: #{message}"}
      {:ok, %{status: status}} -> {:error, "GitHub HTTP #{status}"}
      {:error, _reason} -> {:error, "GitHub request failed"}
    end
  end

  @spec pages((String.t(), String.t(), map() | nil -> term()), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def pages(api, path), do: pages(api, path, 1, [])

  defp pages(_api, _path, 101, _acc), do: {:error, "GitHub pagination exceeded safety limit"}

  defp pages(api, path, page, acc) do
    case api.("get", "#{path}?per_page=100&page=#{page}", nil) do
      {:ok, rows} when is_list(rows) ->
        if length(rows) < 100, do: {:ok, acc ++ rows}, else: pages(api, path, page + 1, acc ++ rows)

      {:error, _reason} = error ->
        error

      _ ->
        {:error, "invalid GitHub collection"}
    end
  end

  defp headers(token), do: [{"authorization", "Bearer " <> token}, {"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]
end
