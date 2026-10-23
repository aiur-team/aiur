defmodule AiurWeb.Build.TicketDocTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.TicketDetail
  alias Aiur.BuildOrder.TicketDetail.{Failure, State}
  alias AiurWeb.Build.TicketDoc

  defp identity do
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "I12", "number" => 12}, {"owner", "repo"}, {"owner", "repo"})
    identity
  end

  defp snapshot(body, user \\ %{"login" => "maya"}) do
    now = DateTime.utc_now()

    raw = %{
      "node_id" => "I12",
      "number" => 12,
      "title" => "Ticket",
      "body" => body,
      "user" => user,
      "html_url" => "https://github.com/owner/repo/issues/12",
      "state" => "open",
      "state_reason" => nil,
      "created_at" => DateTime.to_iso8601(now),
      "updated_at" => DateTime.to_iso8601(now)
    }

    {:ok, detail} = TicketDetail.snapshot(identity(), raw, now: now, relationships: %{nodes: [], truncated?: false})
    detail
  end

  defp state(detail, health \\ :healthy, failure \\ nil), do: {:ok, %State{identity: identity(), generation: 1, health: health, detail: detail, failure: failure}}

  test "normalizer retains valid human and app authors and drops malformed display fields" do
    for login <- ["maya", "dependabot[bot]", "a-b"] do
      assert snapshot("Body", %{"login" => login}).author_login == login
    end

    for user <- [nil, "unexpected", %{}, %{"login" => "<b>x</b>"}, %{"login" => ""}, %{"login" => String.duplicate("x", 40)}] do
      assert snapshot("Body", user).author_login == nil
    end
  end

  test "available body uses escaped Markdown without losing long descriptions or redaction" do
    description = "Summary\n\n#### Scope\n\n- a\n\n<img src=x> [bad](javascript:alert)\n\nAuthorization: Bearer abc123\n\n" <> String.duplicate("long ", 1200)
    doc = TicketDoc.present("12", state(snapshot(description)))
    assert doc.state == "available"
    assert doc.author == "maya"
    assert doc.body_html =~ "<h4>Scope</h4>"
    assert doc.body_html =~ "<li>a</li>"
    assert doc.body_html =~ "&lt;img"
    refute doc.body_html =~ "href=\"javascript:"
    refute doc.body_html =~ "abc123"
    assert byte_size(doc.body_html) > 6000
  end

  test "empty, loading and identity unknown remain distinct" do
    assert %{state: "empty", body_html: nil, reason: nil} = TicketDoc.present("12", state(snapshot(nil)))
    assert %{state: "loading", body_html: nil, reason: nil} = TicketDoc.present("12", state(nil, :unavailable))
    assert %{state: "identity_unknown", reason: "identity_unknown"} = TicketDoc.present("12", :no_identity)
  end

  test "unavailable preserves known failure and retry but collapses unknown causes neutrally" do
    assert %{state: "unavailable", body_html: nil, reason: "rate_limited", retry_after: 30} = TicketDoc.present("12", {:error, %Failure{kind: :rate_limited, retry_after: 30}})
    assert %{state: "unavailable", reason: "evicted"} = TicketDoc.present("12", state(nil, :unavailable, %Failure{kind: :evicted}))

    for input <- [{:error, :boom}, {:error, %Failure{kind: :invented}}] do
      assert %{state: "unavailable", reason: "unknown"} = TicketDoc.present("12", input)
    end
  end

  test "stale retains the observation time and body with either failure or freshness cause" do
    detail = snapshot("Retained")
    doc = TicketDoc.present("12", state(detail, :stale))
    assert doc.state == "stale"
    assert doc.body_html == "<p>Retained</p>"
    assert doc.created == DateTime.to_unix(detail.created_at, :millisecond)
    assert doc.observed_at == DateTime.to_unix(detail.observed_at, :millisecond)
    assert doc.reason == "not_fresh"
    assert TicketDoc.present("12", state(detail, :stale, %Failure{kind: :timeout})).reason == "timeout"
  end

  # Future regression guard; not counted as coverage of the new document producer.
  test "body HTML and document pushes have one production owner" do
    root = Path.expand("../../../lib", __DIR__)
    owners = for path <- Path.wildcard(root <> "/**/*.ex"), String.contains?(File.read!(path), ["body_html", "\"build-ticket-doc\""]), do: Path.relative_to(path, root)
    assert owners == ["aiur_web/build/ticket_doc.ex"]
  end

  test "closed identity lookup failure never claims healthy absence" do
    assert {:error, :identity_lookup_unavailable} =
             TicketDoc.live_identity("12", snapshot_fun: fn -> %Aiur.OpenTicketSource.Snapshot{status: :available} end, history_fun: fn _ -> {:error, :history_unavailable} end)
  end

  test "identity lookup distinguishes missing, degraded and closed tickets" do
    for status <- [:unavailable, :stale, :loading] do
      assert {:error, :open_tickets_unavailable} = TicketDoc.live_identity("12", snapshot_fun: fn -> %Aiur.OpenTicketSource.Snapshot{status: status} end, history_fun: fn _ -> {:ok, [], nil} end)
    end

    assert :no_identity = TicketDoc.live_identity("12", snapshot_fun: fn -> %Aiur.OpenTicketSource.Snapshot{status: :available} end, history_fun: fn _ -> {:ok, [], nil} end)

    assert {:error, :open_tickets_unavailable} =
             TicketDoc.live_identity("12", snapshot_fun: fn -> %Aiur.OpenTicketSource.Snapshot{status: :available, truncated?: true} end, history_fun: fn _ -> {:ok, [], nil} end)

    assert {:ok, found} =
             TicketDoc.live_identity("12", snapshot_fun: fn -> %Aiur.OpenTicketSource.Snapshot{} end, history_fun: fn [12] -> {:ok, [%{node_id: "I12"}], nil} end, configured_repo: {"owner", "repo"})

    assert found == identity()

    assert {:ok, found} =
             TicketDoc.live_identity("12",
               snapshot_fun: fn -> %Aiur.OpenTicketSource.Snapshot{tickets: [%{identifier: "12", identity: identity()}]} end,
               history_fun: fn _ -> flunk("open identity needs no history read") end
             )

    assert found == identity()
  end
end
