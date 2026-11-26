defmodule AiurWeb.ChatRedirectTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest
  import Plug.Conn
  alias AiurWeb.Endpoint
  @endpoint Endpoint

  setup do
    config = Application.get_env(:aiur, Endpoint)
    Application.put_env(:aiur, Endpoint, Keyword.merge(config || [], server: false, dashboard_auth_required: false, secret_key_base: String.duplicate("s", 64)))
    Aiur.TestSupport.start_owned_endpoint!()
    on_exit(fn -> Application.put_env(:aiur, Endpoint, config) end)
    :ok
  end

  test "canonical same-repository chat links redirect temporarily and discard query data" do
    conn = configured() |> get("/chat/OWNER/Repo/7?ticket=8&feature=other")
    assert redirected_to(conn, 302) == "/?ticket=7"
    assert configured() |> get("/chat/owner/repo/9999999999") |> redirected_to(302) == "/?ticket=9999999999"
  end

  test "foreign and malformed links cannot open a different ticket" do
    for path <- [
          "/chat/other/repo/7",
          "/chat/owner/foreign/7",
          "/chat/owner/repo/007",
          "/chat/owner/repo/+7",
          "/chat/owner/repo/AIUR-7",
          "/chat/owner/repo/10000000000",
          "/chat/owner/repo/0",
          "/chat/../repo/7",
          "/chat/owner/a%2Fb/7"
        ] do
      conn = configured() |> get(path)
      assert html_response(conn, 404) =~ "Chat is unavailable for this ticket."
      assert get_resp_header(conn, "location") == []
    end
  end

  test "missing repository returns unavailable rather than guessing" do
    conn = configured() |> put_private(:aiur_configured_repo, fn -> {:error, :missing_configured_repository} end) |> get("/chat/owner/repo/7")
    assert html_response(conn, 503) =~ "The configured repository cannot be read."
    assert get_resp_header(conn, "location") == []
  end

  test "future regression guard: chat redirect is protected by dashboard authentication" do
    Phoenix.Config.put(Endpoint, :dashboard_auth_required, true)
    conn = configured() |> delete_req_header("authorization") |> get("/chat/owner/repo/7")
    assert response(conn, 401)
    assert get_resp_header(conn, "location") == []
  end

  defp configured do
    build_conn()
    |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
    |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
    |> put_private(:aiur_configured_repo, fn -> {:ok, {"owner", "repo"}} end)
  end
end
