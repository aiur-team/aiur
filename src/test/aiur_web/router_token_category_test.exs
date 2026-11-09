defmodule AiurWeb.RouterTokenCategoryTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.{FinancialDataAccess, Router}

  @session_options Plug.Session.init(store: :cookie, key: "_aiur_test_key", signing_salt: "aiur-test-session")

  setup do
    FinancialDataAccess.Generation.invalidate()
    Aiur.TestSupport.start_owned_endpoint!()

    previous_endpoint = Application.get_env(:aiur, AiurWeb.Endpoint)
    previous_writable = AiurWeb.Endpoint.config(:dashboard_writable)
    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.merge(previous_endpoint || [], dashboard_auth_required: true))

    on_exit(fn ->
      if previous_endpoint, do: Application.put_env(:aiur, AiurWeb.Endpoint, previous_endpoint), else: Application.delete_env(:aiur, AiurWeb.Endpoint)
      if Process.whereis(AiurWeb.Endpoint), do: Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, previous_writable)
    end)

    :ok
  end

  test "a partial-category write token is refused on REST write routes except messages" do
    path = Path.join(System.tmp_dir!(), "aiur-router-token-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :client_tokens_path, path)
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, true)
    assert {:ok, token} = Aiur.ClientTokens.create("msg-only", "write", categories: ["read", "message"])

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :client_tokens_path, previous), else: Application.delete_env(:aiur, :client_tokens_path)
      Aiur.TestCleanup.rm_rf!(path)
    end)

    post = fn route ->
      :post
      |> dashboard_conn(route, nil)
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("origin", "http://localhost")
      |> put_req_header("x-aiur-request", "1")
      |> Router.call(Router.init([]))
    end

    assert post.("/api/v1/AIUR-1/pause").status == 403
    assert post.("/api/v1/pane/hide").status == 403
    refute post.("/api/v1/AIUR-1/messages").status in [401, 403]

    read = :get |> dashboard_conn("/api/v1/state", nil) |> put_req_header("authorization", "Bearer #{token}") |> Router.call(Router.init([]))
    assert read.status == 200
  end

  defp dashboard_conn(method, path, credentials) do
    method
    |> conn(path)
    |> Map.put(:secret_key_base, String.duplicate("s", 64))
    |> put_private(:aiur_dashboard_credentials, credentials)
    |> AiurWeb.Session.call(@session_options)
    |> fetch_session()
  end
end
