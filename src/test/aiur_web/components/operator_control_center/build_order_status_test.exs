defmodule AiurWeb.OperatorControlCenterComponentsBuildOrderStatusTest do
  use Aiur.TestSupport

  alias Aiur.BuildOrder.{Diagnostic, ProviderHealth}

  import AiurWeb.OperatorControlCenterComponentsFixtures

  test "a fetched malformed Build Order renders one structural-failure state with its observed count" do
    html =
      render_selected(%{
        unresolved_model(:structurally_invalid)
        | summary: resolved_summary(),
          diagnostics: [Diagnostic.new(:invalid_root)]
      })

    {:ok, document} = Floki.parse_document(html)

    assert [_card] = Floki.find(document, ".bo-state-card")
    assert html =~ "The plan is unreadable"
    assert html =~ "Investigate why Build Order #1567&#39;s plan is unreadable."
    assert html =~ "`invalid_root`"
    assert html =~ "`members: 0`"
    refute html =~ "Build Order graph summary"
    refute html =~ "Unresolved"
    refute html =~ "Plan distribution"
    refute html =~ ">Analytics<"
    refute html =~ "Usage and cost"
    refute html =~ "Root data is unavailable"
  end

  # A malformed graph carries no structural diagnostic when the root summary
  # itself is the defect, so the verdict is the only honest code left.
  test "a malformed Build Order with no structural diagnostic falls back to the structural verdict" do
    html = render_selected(%{unresolved_model(:structurally_invalid) | summary: resolved_summary()})

    assert html =~ "The plan is unreadable"
    assert html =~ "`structurally_invalid`"
  end

  # `SelectedRoot.availability/2` lets a producer fail closed on a structural
  # defect by marking provider health failed, and says that marking "must not be
  # read as an outage". Sourcing the reported fault from health told the operator
  # a graph was malformed *because of* `rate_limited` and sent the debug prompt
  # after an outage that was not the reason for anything.
  test "a malformed Build Order never reports its provider health failure as the structural fault" do
    html =
      render_selected(%{
        unresolved_model(:structurally_invalid)
        | summary: resolved_summary(),
          planning_health: %ProviderHealth{generation: 9, state: :unavailable, failure: :rate_limited},
          diagnostics: [Diagnostic.new(:duplicate_identity)]
      })

    {:ok, document} = Floki.parse_document(html)

    assert [card] = Floki.find(document, ".bo-state-card")
    card_text = Floki.text(card)

    assert html =~ "The plan is unreadable"
    # The code shown is the observed structural defect, not the fetch fault.
    assert card_text =~ "Reported fault: duplicate_identity"
    assert html =~ "The selected-root provider reports `duplicate_identity`"
    refute card_text =~ "rate_limited"
  end

  # Collapsing restatements of one fault is the ask; a graph that is malformed
  # *and* genuinely unreachable has two faults, and the outage must survive.
  test "a malformed Build Order still reports a concurrent provider outage" do
    html =
      render_selected(%{
        unresolved_model(:structurally_invalid)
        | summary: resolved_summary(),
          diagnostics: [Diagnostic.new(:duplicate_identity), Diagnostic.new(:provider_unavailable)]
      })

    assert html =~ "The selected-root provider reports `duplicate_identity`"
    assert html =~ "also reported: `provider_unavailable`"
  end

  # The fallback used to restate the card's own message word for word, which is
  # the restatement pattern this state exists to remove.
  test "a malformed Build Order with unresolved counts adds no restated observation" do
    html = render_selected(%{unresolved_model(:structurally_invalid) | diagnostics: [Diagnostic.new(:invalid_root)]})

    assert html =~ "The selected-root provider reports `invalid_root`."
    refute html =~ "the fetched response failed structural validation"
  end

  # #1808 stopped `failure_class/1` laundering every read fault into
  # `provider_unavailable`. The one error card must report the code the provider
  # actually gave, or the debug prompt sends an agent after the wrong problem.
  test "the single failure state names the specific reported fault, not a generic outage" do
    html =
      render_selected(%{
        unresolved_model(:provider_unavailable)
        | planning_health: %ProviderHealth{generation: 9, state: :unavailable, failure: :rate_limited}
      })

    {:ok, document} = Floki.parse_document(html)

    assert [_card] = Floki.find(document, ".bo-state-card")
    assert html =~ "Reported fault:"
    assert html =~ "`rate_limited`"
    refute html =~ "provider_unavailable"
  end

  # Collapsing restatements of one fault is the point; hiding a second, genuinely
  # different fault would trade a wall of text for a confident wrong reason.
  test "the single failure state still reports genuinely distinct faults" do
    html =
      render_selected(%{
        unresolved_model(:provider_unavailable)
        | planning_health: %ProviderHealth{generation: 9, state: :unavailable, failure: :rate_limited},
          diagnostics: [Diagnostic.new(:provider_unavailable), Diagnostic.new(:pagination_mismatch)]
      })

    {:ok, document} = Floki.parse_document(html)

    assert [_card] = Floki.find(document, ".bo-state-card")
    assert html =~ "also reported: `pagination_mismatch`"
    # `provider_unavailable` here restates the reported fault rather than adding one.
    refute html =~ "provider_unavailable"
  end

  # #2608. The page rendered "Showing the last saved plan." over percentages
  # that were six hours old, beside a catalog summary that was current, with
  # nothing on screen to tell the two apart — a 23% and an 86% for the same
  # root, both looking equally live. A saved plan has to date itself, and the
  # dateline has to ride on the element the percentages are read off.
  test "a saved plan dates itself and marks its percentages as of then" do
    saved_at = ~U[2026-08-10 06:22:11Z]

    html =
      render_selected(%{
        sample_view_model()
        | status: :provider_stale,
          summary: resolved_summary(),
          planning_health: %ProviderHealth{generation: 9, state: :stale, last_success_at: saved_at}
      })

    # The state card says how old the plan is, not merely that it is saved.
    assert html =~ "Showing the last saved plan, read 5h 37m ago."
    assert html =~ "The counts and percentages below are as of then, not now."

    {:ok, document} = Floki.parse_document(html)
    assert [head] = Floki.find(document, ".bo-waves-head")

    # The wave percentages carry the same dateline and the same age, so the two
    # cannot drift into separate accounts of the same moment.
    assert Floki.attribute([head], "class") == ["bo-waves-head is-stale"]
    assert Floki.attribute([head], "aria-label") == ["Wave completion as of the last saved plan"]
    assert Floki.text(head) =~ "As of 06:22:11Z (5h 37m ago) — not current"
    assert Floki.attribute(Floki.find(head, "time"), "datetime") == ["2026-08-10T06:22:11Z"]
  end

  # A saved plan whose provider never reported a success time still has to say
  # its numbers are not live; it just cannot say how stale they are.
  test "a saved plan with no recorded read time still disclaims its percentages" do
    html =
      render_selected(%{
        sample_view_model()
        | status: :provider_stale,
          summary: resolved_summary(),
          planning_health: %ProviderHealth{generation: 9, state: :stale, last_success_at: nil}
      })

    assert html =~ "Showing the last saved plan. The counts and percentages below are as of when it was read, not now."
    # The percentages are just as stale without a read time, so they are marked
    # all the same; only the dateline has nothing to name.
    assert html =~ "is-stale"
    assert html =~ "Wave completion as of the last saved plan"
    assert html =~ "As of an unrecorded read — not current"
  end

  # And the converse, which is what keeps the dateline meaningful: a current
  # plan is current by definition and gets no dateline and no dimming.
  test "a current plan carries no dateline and no stale marking" do
    html =
      render_selected(%{
        sample_view_model()
        | summary: resolved_summary(),
          planning_health: %ProviderHealth{generation: 9, state: :healthy, last_success_at: ~U[2026-08-10 06:22:11Z]}
      })

    refute html =~ "is-stale"
    refute html =~ "not current"
    refute html =~ "last saved plan"
  end
end
