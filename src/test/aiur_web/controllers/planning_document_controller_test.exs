defmodule AiurWeb.PlanningDocumentControllerTest do
  use Aiur.TestSupport
  import Plug.Conn
  import Plug.Test
  alias AiurWeb.BuildOrder.PlanningSource
  alias AiurWeb.{FinancialDataAccess, Router}

  setup do
    FinancialDataAccess.Generation.invalidate()
    Aiur.TestSupport.start_owned_endpoint!()
    directory = Aiur.TestSupport.tmp_root!("planning-document")
    File.mkdir_p!(Path.join(directory, "tickets"))
    path = Path.join(directory, "build-order.json")
    previous = Application.get_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    File.write!(
      path,
      Jason.encode!(%{
        build_order_id: "owner/repo:document",
        title: "Document plan",
        repository: "owner/repo",
        root_number: 9900,
        tickets: [%{id: "DRAFT-1", title: "Draft", lane: "core", phase: 1, ticket: nil, doc: "tickets/DRAFT-1.md", depends_on: []}]
      })
    )

    body = "Full draft introduction\n" <> String.duplicate("remaining text ", 400) <> "\npassword=private-credential\n"
    File.write!(Path.join(directory, "tickets/DRAFT-1.md"), body)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :build_order_planning_pack, previous), else: Application.delete_env(:aiur, :build_order_planning_pack)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "future regression guard: full draft document requires dashboard authentication" do
    response = request("/build-order-documents/owner/repo/9900/42", false)
    assert response.status == 401
    assert get_resp_header(response, "www-authenticate") == ["Basic realm=\"Aiur\""]
  end

  test "authenticated documents retain the sanitized body beyond the preview limit" do
    [root] = PlanningSource.catalog().data.entries
    {:ok, selected} = PlanningSource.demand(root.identity)
    [member] = selected.data.members
    response = request("/build-order-documents/owner/repo/9900/#{member.identity.identifier}")
    assert response.status == 200
    assert byte_size(response.resp_body) > 4_000
    assert response.resp_body =~ "Full draft introduction"
    assert response.resp_body =~ "remaining text"
    refute response.resp_body =~ "private-credential"
    assert get_resp_header(response, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
  end

  test "document links cannot escape the pack through a symlink", %{directory: directory} do
    outside = Aiur.TestSupport.tmp_root!("outside-pack-document") <> ".md"
    File.write!(outside, "Outside document must remain private")
    on_exit(fn -> File.rm(outside) end)
    doc = Path.join(directory, "tickets/DRAFT-1.md")
    File.rm!(doc)
    File.ln_s!(outside, doc)
    [root] = PlanningSource.catalog().data.entries
    {:ok, selected} = PlanningSource.selected(root.identity)
    [member] = selected.data.members
    assert member.draft_body == nil
    response = request("/build-order-documents/owner/repo/9900/#{member.identity.identifier}")
    assert response.status == 404
    refute response.resp_body =~ "Outside document"
  end

  test "future regression guard: invalid locators and missing members return unavailable" do
    for path <- ["/build-order-documents/owner/repo/09900/42", "/build-order-documents/owner/repo/9900/42", "/build-order-documents/other/repo/9900/42"] do
      response = request(path)
      assert response.status == 404
      assert response.resp_body == "Planning document unavailable"
    end
  end

  defp request(path, authenticated? \\ true) do
    request = conn(:get, path) |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
    request = if authenticated?, do: put_req_header(request, "authorization", "Basic " <> Base.encode64("operator:secret")), else: request
    Router.call(request, Router.init([]))
  end
end
