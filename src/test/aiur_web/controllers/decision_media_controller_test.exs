Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule AiurWeb.DecisionMediaControllerTest do
  use Aiur.DecisionStoreCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.DecisionApi.PublicProjection
  alias AiurWeb.DecisionMediaController

  setup do
    base = Aiur.DecisionValidation.safe_roots() |> Enum.find(&(Path.type(&1) == :absolute))
    root = Path.join(base, "aiur-media-serve-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    path = Path.join(root, "evidence.png")
    File.write!(path, "png-bytes")

    %{root: root, path: path}
  end

  defp show(store, decision_id, attachment_id) do
    conn(:get, "/api/v1/decisions/#{decision_id}/media/#{attachment_id}")
    |> put_private(:decision_media_store, store)
    |> DecisionMediaController.show(%{"decision_id" => decision_id, "attachment_id" => attachment_id})
  end

  test "serves a local attachment that belongs to the Command", %{dir: dir, path: path} do
    store = start_store!(dir)

    assert {:ok, %{decision: decision}} =
             request(store, %{
               question: "Which layout?",
               blocking: false,
               media: [%{"kind" => "image", "mime_type" => "image/png", "locator" => path, "alt_text" => "Evidence"}]
             })

    attachment_id = hd(PublicProjection.encode(decision)["media"])["attachment_id"]
    conn = show(store, decision.decision_id, attachment_id)

    assert conn.status == 200
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert conn.resp_body == "png-bytes"

    GenServer.stop(store)
  end

  test "refuses a file that resolves outside the safe root at read time", %{dir: dir, path: path} do
    store = start_store!(dir)

    assert {:ok, %{decision: decision}} =
             request(store, %{
               question: "Which layout?",
               blocking: false,
               media: [%{"kind" => "image", "mime_type" => "image/png", "locator" => path, "alt_text" => "Evidence"}]
             })

    attachment_id = hd(PublicProjection.encode(decision)["media"])["attachment_id"]

    # A symlink swapped in after ingestion must not escape the safe root.
    File.rm!(path)
    File.ln_s!("/etc/passwd", path)

    assert show(store, decision.decision_id, attachment_id).status == 404

    GenServer.stop(store)
  end

  test "refuses an attachment that belongs to another Command", %{dir: dir, path: path} do
    store = start_store!(dir)

    assert {:ok, %{decision: with_media}} =
             request(store, %{
               question: "A?",
               blocking: false,
               source_id: "with-media",
               media: [%{"kind" => "image", "mime_type" => "image/png", "locator" => path, "alt_text" => "Evidence"}]
             })

    attachment_id = hd(PublicProjection.encode(with_media)["media"])["attachment_id"]

    assert {:ok, %{decision: without_media}} = request(store, %{question: "B?", blocking: false, source_id: "no-media"})

    assert show(store, without_media.decision_id, attachment_id).status == 404
    assert show(store, "dec_missing", attachment_id).status == 404

    GenServer.stop(store)
  end

  test "answers 503 when the Decision store is unavailable" do
    assert show(NotARunningStore, "dec_x", "med_000").status == 503
  end
end
