defmodule AiurWeb.OperatorControlCenter.DecisionOverridesTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import AiurWeb.OperatorControlCenterComponentsFixtures
  alias AiurWeb.OperatorControlCenter.{DecisionCard, DecisionDetail, DecisionPresenter}

  @ticket %{identifier: "42", url: "https://github.com/owner/repo/issues/42"}

  test "detail renders each override state as a list with actor, time and links" do
    cases = [
      {%{state: :queued, route: :active_worker}, "Queued"},
      {%{state: :queued, route: :capacity_wait}, "Queued — waiting for a slot"},
      {%{state: :queued, route: :resume_pending}, "Queued — resuming #42"},
      {%{state: :delivered}, "Delivered"},
      {%{state: :delivered, evidence: %{kind: :push, worker_reported: true, pr_number: 71}}, "Implemented in PR #71 (awaiting merge)"},
      {%{state: :implemented, evidence: %{pr_number: 71}}, "Implemented in PR #71"},
      {%{state: :queued, corrective_ticket: %{identifier: "99", url: "https://github.com/owner/repo/issues/99"}}, "Corrective ticket #99 · queued"},
      {%{state: :superseded}, "Superseded"}
    ]

    for {attrs, label} <- cases do
      row = row(attrs)
      html = render_component(&DecisionDetail.decision_detail/1, decision: row, writable: false)
      timeline = html |> Floki.parse_fragment!() |> Floki.find("section[aria-label=Overrides] ol li")
      assert length(timeline) == 1
      assert timeline |> Floki.find(".chip") |> Floki.text() == label
      assert timeline |> Floki.find("time") |> Floki.text() == DateTime.to_iso8601(row.created_at)
      assert Floki.text(timeline) =~ "operator"
      assert timeline |> Floki.find("a[href='/commands/cmd-overrides']") |> Floki.text() == "Original Command"
      assert timeline |> Floki.find("a[href='https://github.com/owner/repo/issues/42']") |> Floki.text() == "Ticket #42"
      assert timeline |> Floki.find("a[href='https://github.com/owner/repo/pull/71']") |> Floki.text() == "PR #71"
      if attrs[:corrective_ticket], do: assert(timeline |> Floki.find("a[href='https://github.com/owner/repo/issues/99']") |> Floki.text() == "Corrective ticket #99")
    end
  end

  test "corrective implementation links both the original and corrective PRs" do
    row = row(%{state: :implemented, corrective_ticket: %{identifier: "99", url: "https://github.com/owner/repo/issues/99"}, evidence: %{kind: :merge, pr_number: 72}})
    html = render_component(&DecisionDetail.decision_detail/1, decision: row, writable: false)
    timeline = html |> Floki.parse_fragment!() |> Floki.find(".override-timeline")
    assert timeline |> Floki.find("a[href='https://github.com/owner/repo/pull/71']") |> Floki.text() == "Original PR #71"
    assert timeline |> Floki.find("a[href='https://github.com/owner/repo/pull/72']") |> Floki.text() == "PR #72"
    assert timeline |> Floki.find("a[href='https://github.com/owner/repo/issues/99']") |> Floki.text() == "Corrective ticket #99"
  end

  test "inbox and history show a pending override badge until canonical implementation or supersession" do
    for state <- [:queued, :delivered, :failed, :implemented, :superseded] do
      row = row(%{state: state})
      card = render_component(&DecisionCard.decision_card/1, decision: row, now: DateTime.utc_now(), writable: false)

      for html <- [card, render_history([row])] do
        badge = html |> Floki.parse_fragment!() |> Floki.find(".override-badge")
        assert badge != [] == state not in [:implemented, :superseded]
        if badge != [], do: assert(Floki.text(badge) =~ "Override ·")
      end
    end
  end

  test "future regression guard: delivered answer keeps the writable override form" do
    html = render_component(&DecisionDetail.decision_detail/1, decision: row(%{state: :delivered}), writable: true)
    assert html |> Floki.parse_fragment!() |> Floki.find("form[phx-submit=revise-decision]") |> length() == 1
    refute html =~ "Send a follow-up message instead"
  end

  test "an unattested push remains delivered" do
    [override] = Aiur.Commands.override_rows(row(%{state: :delivered, evidence: %{kind: :push, worker_reported: false, pr_number: 71}}))
    assert override.label == "Delivered"
    assert override.pending?
  end

  test "unknown override status remains explicit instead of a plausible delivered default" do
    [unknown] = Aiur.Commands.override_rows(row(%{state: :unknown}))
    assert unknown.label == "Override status unknown"
  end

  test "unsafe ticket URLs never become timeline links" do
    [override] =
      Aiur.Commands.override_rows(%{
        decision_id: "safe",
        overrides: [%{state: :queued, ticket: %{identifier: "42", url: "javascript:alert(1)"}, corrective_ticket: %{identifier: "99", url: "data:text/html,bad"}}]
      })

    assert override.links == [%{label: "Original Command", href: "/commands/safe"}]
  end

  defp row(attrs) do
    now = DateTime.utc_now()
    answer = action_answer(:operator, action_id: "override-1", id: "operator-override")
    answer = %{answer | actor: %{kind: :operator, id: "operator-override"}}

    record =
      Map.merge(%{action_id: "override-1", state: :queued, route: :active_worker, ticket: @ticket, pr_number: 71, queued_at: now, delivered_at: nil, implemented_at: nil, superseded_at: nil}, attrs)

    decision = struct(Aiur.Decision, Map.take(inbox_decision("cmd-overrides"), Map.keys(Map.from_struct(struct(Aiur.Decision)))))

    revision =
      struct(Aiur.DecisionRevision, %{
        sequence: 1,
        action_id: "override-1",
        prior_action_id: "original",
        answer: struct(Aiur.DecisionAnswer, Map.take(answer, Map.keys(Map.from_struct(struct(Aiur.DecisionAnswer))))),
        reason: "New direction",
        recorded_at: now
      })

    [row] =
      DecisionPresenter.present(%{
        decision
        | created_at: now,
          ticket: @ticket,
          answer: revision.answer,
          active_action_id: "override-1",
          revisions: [revision],
          overrides: [record],
          decision_status: :decided,
          delivery_status: :delivered
      })

    row
  end
end
