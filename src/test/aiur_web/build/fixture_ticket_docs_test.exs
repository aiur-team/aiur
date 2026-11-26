defmodule AiurWeb.Build.FixtureTicketDocsTest do
  use Aiur.TestSupport

  alias Aiur.TestSupport.BuildHome.{FixtureSource, TicketDocs}
  alias Aiur.TrackerIdentity
  alias AiurWeb.Markdown

  test "fixture identity reads a normalized frozen body and its seeded author" do
    for dataset <- ~w(live dense newrepo noqueue offline now0 now24) do
      assert {:ok, data} = FixtureSource.full(dataset: dataset)
      row = hd(data["sections"]["plan"] ++ data["sections"]["nq"] ++ data["sections"]["now"])
      assert {:ok, identity} = FixtureSource.ticket_doc_identity(row["id"], dataset: dataset)
      assert TrackerIdentity.joinable?(identity)
      assert identity.provider_id == "build-fixture:#{dataset}:#{row["id"]}"
      assert {:ok, state} = TicketDocs.request(identity)
      assert state.health == :healthy
      assert state.detail.identity == identity
      assert state.detail.title == row["title"]
      assert DateTime.to_unix(state.detail.observed_at, :millisecond) == data["now"]
      docs = "test/fixtures/build_home/docs-#{dataset}.json" |> File.read!() |> Jason.decode!()
      assert state.detail.description == docs[row["id"]]["body_md"]
      assert state.detail.author_login == docs[row["id"]]["author"]
      html = state.detail.description |> Markdown.render() |> Phoenix.HTML.safe_to_string()
      assert html =~ "<h4>Scope</h4>"
      assert html =~ "<h4>Done when</h4>"
      assert html =~ "<ul>"
    end
  end

  # Future regression guard; not counted as coverage of the new document producer.
  test "fixture doc does not invent an identity or read an arbitrary dataset path" do
    assert FixtureSource.ticket_doc_identity("missing", dataset: "live") == {:error, :not_found}
    assert TicketDocs.request(%TrackerIdentity{provider_id: "build-fixture:../live:351"}) == {:error, :fixture_doc_unavailable}
    assert TicketDocs.request(nil) == {:error, :fixture_doc_unavailable}
  end
end
