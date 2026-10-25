defmodule Aiur.Netlify.ClientTest do
  use ExUnit.Case, async: true
  alias Aiur.Netlify.Client

  test "parses recorded account, audit, bandwidth, site and deploy responses" do
    bodies = %{
      "/accounts/acct" => fixture("account.json"),
      "/accounts/acct/audit?per_page=100" => fixture("audit.json"),
      "/accounts/acct/bandwidth" => fixture("bandwidth.json"),
      "/sites?per_page=100" => fixture("sites.json"),
      "/sites/site-1/deploys?per_page=100&from=2026-10-01T00:00:00Z" => fixture("deploys.json")
    }

    request = fn %{url: url, token: token, caller: caller} ->
      assert token == "test-token"
      assert caller == "netlify_usage"
      path = URI.parse(url).path |> String.replace_prefix("/api/v1", "")
      query = URI.parse(url).query |> then(&if(&1, do: URI.decode_query(&1), else: %{}))

      suffix =
        case path do
          "/accounts/acct/audit" -> "?per_page=#{query["per_page"]}"
          "/sites" -> "?per_page=#{query["per_page"]}"
          "/sites/site-1/deploys" -> "?per_page=#{query["per_page"]}&from=#{query["from"]}"
          _ -> ""
        end

      case Map.fetch(bodies, path <> suffix) do
        {:ok, body} -> {:ok, %{status: 200, body: body}}
        :error -> {:error, :unmatched_fixture}
      end
    end

    assert {:ok, data} = Client.fetch("acct", "test-token", request_fun: request, now: ~U[2026-10-25 12:00:00Z])
    assert data.account["plan_credits"] == 500
    assert length(data.audit) == 6
    assert data.bandwidth == fixture("bandwidth.json")
    assert [%{id: "site-1", production_deploys: 1}] = data.sites
  end

  test "404 deploy history is treated as an empty site history" do
    request = fn %{url: url} ->
      cond do
        String.ends_with?(url, "/accounts/acct") -> {:ok, %{status: 200, body: fixture("account.json")}}
        String.contains?(url, "/audit?") -> {:ok, %{status: 200, body: fixture("audit.json")}}
        String.contains?(url, "/bandwidth") -> {:ok, %{status: 200, body: fixture("bandwidth.json")}}
        String.contains?(url, "/sites?") -> {:ok, %{status: 200, body: fixture("sites.json")}}
        String.contains?(url, "/deploys?") -> {:ok, %{status: 404, body: %{}}}
      end
    end

    assert {:ok, %{sites: [%{production_deploys: 0}]}} = Client.fetch("acct", "token", request_fun: request, now: ~U[2026-10-25 12:00:00Z])
  end

  test "recorded balance endpoints remain unsupported and are not guessed" do
    fixture = fixture("unsupported-balance-endpoints.json")
    assert Enum.all?(fixture, fn {_path, response} -> response["status"] == 404 end)
    refute Map.has_key?(fixture, "/api/v1/accounts/acct")
  end

  defp fixture(name), do: Path.join(__DIR__, "../../fixtures/netlify/#{name}") |> Path.expand() |> File.read!() |> Jason.decode!()
end
