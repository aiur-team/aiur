defmodule Aiur.Netlify.Client do
  @moduledoc "Read-only Netlify API client for account credit and deploy usage."
  alias Aiur.GitHub.Transport

  @caller "netlify_usage"

  @spec fetch(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(account_id, token, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    request = Keyword.get(opts, :request_fun, &default_request/1)

    with {:ok, account} <- get_map(request, token, "/accounts/#{URI.encode(account_id)}"),
         {:ok, audit} <- get_list(request, token, "/accounts/#{URI.encode(account_id)}/audit?per_page=100"),
         {:ok, bandwidth} <- get_map(request, token, "/accounts/#{URI.encode(account_id)}/bandwidth"),
         {:ok, sites} <- get_list(request, token, "/sites?per_page=100"),
         {:ok, sites} <- fetch_deploys(request, token, sites, account["current_billing_period_start"], now) do
      {:ok, %{account: account, audit: audit, bandwidth: bandwidth, sites: sites, fetched_at: now}}
    end
  end

  defp fetch_deploys(request, token, sites, start_at, now) do
    Enum.reduce_while(sites, {:ok, []}, fn site, {:ok, acc} ->
      from = start_at || DateTime.to_iso8601(DateTime.add(now, -30, :day))
      path = "/sites/#{URI.encode(to_string(site["id"]))}/deploys?per_page=100&from=#{URI.encode(from)}"

      case get_list(request, token, path, missing_ok: true) do
        {:ok, deploys} ->
          count = Enum.count(deploys, &production_deploy?/1)
          {:cont, {:ok, [%{id: site["id"], name: site["name"], production_deploys: count} | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp get_map(request, token, path) do
    case request.(request_map(token, path)) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      _ -> {:error, :request_failed}
    end
  end

  defp get_list(request, token, path, opts \\ []) do
    case request.(request_map(token, path)) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: 404}} -> if Keyword.get(opts, :missing_ok, false), do: {:ok, []}, else: {:error, {:http, 404}}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      _ -> {:error, :request_failed}
    end
  end

  defp request_map(token, path), do: %{url: "https://api.netlify.com/api/v1" <> path, token: token, caller: @caller}
  defp production_deploy?(%{"context" => "production", "state" => "ready"}), do: true
  defp production_deploy?(%{"context" => "production"}), do: true
  defp production_deploy?(_), do: false

  @spec default_request(map()) :: {:ok, map()} | {:error, term()}
  def default_request(%{url: url, token: token, caller: @caller} = request) do
    Transport.off_process_request(request, fn ->
      case Req.get(url, headers: [{"Authorization", "Bearer " <> token}, {"Accept", "application/json"}], receive_timeout: 20_000, retry: false) do
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, _} -> {:error, :request_failed}
      end
    end)
  end
end
