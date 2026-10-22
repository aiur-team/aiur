defmodule AiurWeb.UsageAccountsApiControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Aiur.Accounts
  alias Aiur.Accounts.UsageReadings
  alias AiurWeb.Router

  @path "/api/v1/usage/accounts"
  @access_token "sk-ant-oat01-never-in-the-snapshot"
  @api_key "sk-ant-api03-never-in-the-snapshot"

  setup do
    Aiur.TestSupport.start_owned_endpoint!()
    UsageReadings.reset()
    home = Aiur.TestSupport.tmp_root!("aiur-usage-accounts-api")
    File.mkdir_p!(Path.join(home, ".claude"))
    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    # The default Claude profile holds both identity and credentials on disk;
    # the snapshot may read the identity labels and nothing else.
    File.write!(
      Path.join(home, ".claude.json"),
      Jason.encode!(%{"primaryApiKey" => @api_key, "oauthAccount" => %{"emailAddress" => "dev@example.com", "organizationName" => "Example", "subscriptionType" => "max"}})
    )

    File.write!(Path.join(home, ".claude/.credentials.json"), Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => @access_token, "refreshToken" => @access_token}}))

    on_exit(fn ->
      UsageReadings.reset()
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      Aiur.TestCleanup.rm_rf!(home)
    end)

    %{home: home}
  end

  test "each configured account carries its polled usage and how fresh it is" do
    :ok = Accounts.register("claude", "work", nil)
    UsageReadings.record("claude", "default", {:ok, %{windows: [%{window: "seven_day", used_percent: 36}, %{window: "five_hour", used_percent: 50}]}}, DateTime.utc_now())

    body = get_json(@path <> "?harness=claude")

    assert %{"contract" => "aiur.usage.accounts", "contract_version" => 1, "observed_at" => observed_at} = body
    assert {:ok, _, _} = DateTime.from_iso8601(observed_at)

    assert %{"weekly_percent" => 36, "five_hour_percent" => 50, "remaining_percent" => 50, "freshness" => "fresh", "email" => "dev@example.com", "org" => "Example", "seat_tier" => "max"} =
             account(body, "claude", "default")

    assert %{"age_ms" => age_ms, "observed_at" => reading_at} = account(body, "claude", "default")
    assert is_integer(age_ms) and is_binary(reading_at)

    # The daemon has not polled this account yet: say so, never report 0%.
    assert %{"freshness" => "usage_not_observed", "weekly_percent" => nil, "five_hour_percent" => nil, "remaining_percent" => nil, "age_ms" => nil} =
             account(body, "claude", "work")
  end

  test "an old reading is marked stale and keeps its age, and a failed poll names its reason" do
    :ok = Accounts.register("claude", "work", nil)
    old = DateTime.add(DateTime.utc_now(), -3_600)
    UsageReadings.record("claude", "default", {:ok, %{windows: [%{window: "seven_day", used_percent: 80}]}}, old)
    UsageReadings.record("claude", "work", {:error, :no_oauth_token}, DateTime.utc_now())

    body = get_json(@path <> "?harness=claude")

    # Dispatch scores a reading this old as unknown, so a client must not read it as current.
    assert %{"freshness" => "stale", "weekly_percent" => 80, "age_ms" => age_ms} = account(body, "claude", "default")
    assert age_ms >= 3_600_000
    assert %{"freshness" => "no_oauth_token", "weekly_percent" => nil} = account(body, "claude", "work")
  end

  test "without a harness filter every registered backend account is listed" do
    body = get_json(@path)
    harnesses = body["accounts"] |> Enum.map(& &1["harness"]) |> Enum.uniq()

    assert "claude" in harnesses
    assert "codex" in harnesses
    assert Enum.all?(body["accounts"], &is_binary(&1["freshness"]))
    assert get_json(@path <> "?harness=claude")["accounts"] |> Enum.all?(&(&1["harness"] == "claude"))
  end

  test "the snapshot exposes identity labels only: no credentials, keys, or profile paths", %{home: home} do
    :ok = Accounts.register("claude", "work", nil)
    UsageReadings.record("claude", "default", {:ok, %{windows: [%{window: "seven_day", used_percent: 10}]}}, DateTime.utc_now())

    response = request(:get)
    assert response.status == 200
    refute response.resp_body =~ @access_token
    refute response.resp_body =~ @api_key
    refute response.resp_body =~ home
    refute private_key?(Jason.decode!(response.resp_body))
  end

  test "is not shadowed by the issue route and forbids caching" do
    response = request(:get)
    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "non-GET methods return 405 with GET allowed" do
    for method <- [:post, :put, :patch, :delete] do
      response = request(method)
      assert response.status == 405
      assert get_resp_header(response, "allow") == ["GET"]
    end
  end

  # Usage and identity sit behind the same dashboard auth as /api/v1/state.
  test "dashboard credentials are required and wrong credentials fail" do
    for authorization <- [nil, Plug.BasicAuth.encode_basic_auth("operator", "wrong")] do
      response = request(:get, authorization)
      assert response.status == 401
    end
  end

  test "unconfigured auth fails closed with the same boundary as state" do
    for path <- [@path, "/api/v1/state"] do
      response = conn(:get, path) |> put_private(:aiur_dashboard_credentials, nil) |> Router.call(Router.init([]))
      assert response.status in [401, 503]
      assert response.halted
    end
  end

  defp account(body, harness, name), do: Enum.find(body["accounts"], &(&1["harness"] == harness and &1["name"] == name))

  defp get_json(path) do
    response = request(:get, Plug.BasicAuth.encode_basic_auth("operator", "secret"), path)
    assert response.status == 200
    Jason.decode!(response.resp_body)
  end

  defp request(method, authorization \\ Plug.BasicAuth.encode_basic_auth("operator", "secret"), path \\ @path) do
    # Plug.Parsers runs in the endpoint, ahead of the router this calls.
    connection = conn(method, path) |> fetch_query_params() |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
    connection = if authorization, do: put_req_header(connection, "authorization", authorization), else: connection
    Router.call(connection, Router.init([]))
  end

  defp private_key?(value) when is_map(value),
    do: Enum.any?(value, fn {key, item} -> key in ~w(token access_token refresh_token api_key api_key_env primaryApiKey credentials profile_dir password) or private_key?(item) end)

  defp private_key?(value) when is_list(value), do: Enum.any?(value, &private_key?/1)
  defp private_key?(_value), do: false
end
