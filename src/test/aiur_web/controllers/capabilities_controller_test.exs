defmodule AiurWeb.CapabilitiesControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias AiurWeb.Router

  defmodule OrchestrationProvider do
    @behaviour Aiur.Capabilities.Provider
    @impl true
    def capability_ids, do: ["orchestration"]
    @impl true
    def capabilities(_context) do
      %{"orchestration" => %{state: :unavailable, reason: :not_running, observed_at: ~U[2026-10-09 12:00:00Z]}}
    end
  end

  setup do
    Aiur.TestSupport.start_owned_endpoint!()
    :ok
  end

  test "capabilities is not shadowed by the issue route and forbids caching" do
    response = request(:get)
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["contract"] == "aiur.capabilities"
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "non-GET methods return 405 with GET allowed" do
    for method <- [:post, :put, :patch, :delete] do
      response = request(method)
      assert response.status == 405
      assert get_resp_header(response, "allow") == ["GET"]
    end
  end

  # Future regression guard: authentication already protects the old issue route.
  test "dashboard credentials are required and wrong credentials fail" do
    for authorization <- [nil, Plug.BasicAuth.encode_basic_auth("operator", "wrong")] do
      response = request(:get, authorization)
      assert response.status == 401
    end
  end

  # Future regression guard: unconfigured auth already fails closed on the old issue route.
  test "unconfigured auth fails closed with the same boundary as state" do
    for path <- ["/api/v1/capabilities", "/api/v1/state"] do
      response = conn(:get, path) |> put_private(:aiur_dashboard_credentials, nil) |> Router.call(Router.init([]))
      assert response.status in [401, 503]
      assert response.halted
    end
  end

  test "answers with a missing registry and unavailable orchestration" do
    previous = Application.get_env(:aiur, :capability_providers)
    Application.put_env(:aiur, :capability_providers, [OrchestrationProvider])
    on_exit(fn -> Application.put_env(:aiur, :capability_providers, previous) end)
    :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Capabilities.Monitor)
    :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Capabilities.Table)

    on_exit(fn ->
      {:ok, _table} = Supervisor.restart_child(Aiur.Supervisor, Aiur.Capabilities.Table)
      {:ok, _monitor} = Supervisor.restart_child(Aiur.Supervisor, Aiur.Capabilities.Monitor)
    end)

    assert :ets.whereis(:aiur_capabilities) == :undefined
    response = request(:get)
    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    assert body["freshness"] == "stale"
    assert body["capabilities"]["orchestration"] == %{"state" => "unavailable", "reason" => "not_running", "observed_at" => "2026-10-09T12:00:00Z"}
  end

  test "public payload contains no private keys or secret-shaped values" do
    response = request(:get)
    assert response.status == 200
    refute secret_value?(Jason.decode!(response.resp_body))
    refute private_key?(Jason.decode!(response.resp_body))
  end

  defp request(method, authorization \\ Plug.BasicAuth.encode_basic_auth("operator", "secret")) do
    connection = conn(method, "/api/v1/capabilities") |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
    connection = if authorization, do: put_req_header(connection, "authorization", authorization), else: connection
    Router.call(connection, Router.init([]))
  end

  defp secret_value?(value) when is_map(value), do: Enum.any?(Map.values(value), &secret_value?/1)
  defp secret_value?(value) when is_list(value), do: Enum.any?(value, &secret_value?/1)
  defp secret_value?(value) when is_binary(value), do: Regex.match?(~r/(ghp_|github_pat_|sk-|\/home\/|:\d{4,5}\b)/, value)
  defp secret_value?(_value), do: false

  defp private_key?(value) when is_map(value), do: Enum.any?(value, fn {key, item} -> key in ~w(token password path detail) or private_key?(item) end)
  defp private_key?(value) when is_list(value), do: Enum.any?(value, &private_key?/1)
  defp private_key?(_value), do: false
end
