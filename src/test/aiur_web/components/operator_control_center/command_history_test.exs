defmodule AiurWeb.OperatorControlCenterComponentsCommandHistoryTest do
  use Aiur.TestSupport

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.{DecisionAction, DecisionCard, DecisionLatency}

  import AiurWeb.OperatorControlCenterComponentsFixtures

  test "renders answered and dismissed Commands once as green history table rows" do
    answered = inbox_decision("dec-history-answered", decision_status: :decided, answer: action_answer(:operator))
    dismissed = inbox_decision("dec-history-dismissed", decision_status: :dismissed)

    html = render_history([answered, dismissed])

    assert html =~ ~s(<table id="command-history-table" class="history-table")
    assert html =~ ~s(data-severity="good")
    assert html =~ "Answered"
    assert html =~ "Closed without a recorded answer"
    refute html =~ ~s(class="decision-card)
  end

  test "renders expired Commands as non-actionable history with no decision to report" do
    expired = inbox_decision("dec-history-expired", decision_status: :expired)

    html = render_history([expired])

    assert html =~ "Expired"
    assert html =~ ~s(<td class="history-decision" data-sort-value="N/A">N/A</td>)
    assert html =~ ~s(data-severity="attn")
    refute html =~ ~s(class="decision-card)
  end

  test "keeps an expired unanswered blocking Command answerable in the open inbox" do
    expired = inbox_decision("dec-expired-blocking", decision_status: :expired, blocking: true)

    html = render_inbox([expired], :open)

    assert html =~ "Question dec-expired-blocking"
    answer = render_component(&DecisionAction.decision_action/1, %{decision: expired, state: %{}, writable: true})
    assert answer =~ ~s(phx-submit="answer-decision")
    assert html =~ "Expired"
    assert html =~ ~s(class="decision-card)
  end

  test "quotes the answer the operator actually recorded in the Decision column" do
    custom =
      inbox_decision("dec-history-custom",
        decision_status: :decided,
        answer: action_answer(:operator, custom_response: "it is the executor's job to review", selected_option_id: nil)
      )

    chosen = inbox_decision("dec-history-option", decision_status: :decided, answer: action_answer(:operator))

    html = render_history([custom, chosen])

    assert html =~ ~s(<th scope="col" data-sort-key="decision">Decision</th>)
    refute html =~ "Outcome</th>"
    assert html =~ "“it is the executor&#39;s job to review”"
    assert html =~ "“Ship it”"
  end

  test "stacks each history result with its raised timestamp in one column" do
    answered = inbox_decision("dec-history-stacked", decision_status: :decided, answer: action_answer(:operator))

    document =
      [answered]
      |> render_history()
      |> Floki.parse_document!()

    timestamp = DateTime.to_iso8601(answered.created_at)

    assert Floki.find(document, ".history-table thead th") |> Enum.map(&Floki.text/1) == ["Command", "Decision", "Result"]
    assert [result_cell] = Floki.find(document, ".history-row > td.history-result-cell:has(.history-result):has(.history-when)")
    assert Floki.attribute(result_cell, "data-sort-value") == [timestamp]
    assert Floki.attribute(result_cell, ".history-when time", "datetime") == [timestamp]
    assert Floki.text(result_cell |> Floki.find(".history-when") |> List.first()) =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/
    assert render_history([answered], expanded_id: answered.decision_id) =~ ~s(<td colspan="3">)
  end

  test "quotes only what somebody actually said, never a status sentence or a blank answer" do
    deferred = inbox_decision("dec-quote-deferred", decision_status: :deferred)
    dismissed = inbox_decision("dec-quote-dismissed", decision_status: :dismissed)
    expired = inbox_decision("dec-quote-expired", decision_status: :expired)

    blank =
      inbox_decision("dec-quote-blank",
        decision_status: :decided,
        answer: action_answer(:operator, custom_response: "   ", selected_option_id: nil)
      )

    html = render_history([deferred, dismissed, expired, blank])

    # These are the component describing a lifecycle, not repeating an answer,
    # so none of them may wear quotation marks.
    assert html =~ ~s(<td class="history-decision" data-sort-value="Handed to the Executor">Handed to the Executor</td>)

    assert html =~
             ~s(<td class="history-decision" data-sort-value="Closed without a recorded answer">Closed without a recorded answer</td>)

    assert html =~ ~s(<td class="history-decision" data-sort-value="N/A">N/A</td>)
    assert html =~ ~s(<td class="history-decision" data-sort-value="">—</td>)
    refute html =~ "“”"
  end

  test "opens a history row as an accordion in place instead of a top-of-page panel" do
    answered =
      inbox_decision("dec-history-open",
        decision_status: :decided,
        answer: action_answer(:operator),
        context: %{short: "Reviewer capacity", long_markdown: "The queue is full."}
      )

    collapsed = render_history([answered])
    expanded = render_history([answered], expanded_id: "dec-history-open")

    # The whole row is the click target, and the control inside it is a real
    # button carrying aria-expanded — not a link that only a mouse can reach.
    assert collapsed =~ ~s(phx-click)
    assert collapsed =~ ~s(class="history-row-toggle" aria-expanded="false")
    refute collapsed =~ ">Open</a>"
    refute collapsed =~ "history-detail-row"

    assert expanded =~ ~s(aria-expanded="true")

    assert expanded =~
             ~s(<tr id="history-detail-history-dec-history-open" class="history-detail-row" data-sort-detail-for="history-dec-history-open">)

    assert expanded =~ "The queue is full."
    assert expanded =~ "Event timeline"
  end

  test "keeps deferred, expired and answered outcomes visually distinct in history" do
    rows = [
      inbox_decision("dec-answered", decision_status: :decided, answer: action_answer(:operator)),
      inbox_decision("dec-deferred", decision_status: :deferred),
      inbox_decision("dec-expired", decision_status: :expired)
    ]

    html = render_history(rows)

    assert html =~ "Deferred to Executor"
    assert html =~ "Handed to the Executor"
    assert html =~ "Expired"
    assert html =~ "Answered"
    assert html =~ ~s(data-severity="attention")
  end

  test "offers load more only while the store reports another page, and never guesses a total" do
    rows = Enum.map(1..10, &inbox_decision("dec-#{&1}", decision_status: :decided, answer: action_answer(:operator)))

    more = render_history(rows, has_more: true, total: 34)
    final = render_history(rows, has_more: false, total: nil)

    assert more =~ ~s(phx-click="load-more-history")
    assert more =~ "10 of 34"
    refute final =~ ~s(phx-click="load-more-history")
    assert final =~ "10 loaded"
  end

  test "Commands inbox exposes only the four primary filters with canonical retained counts" do
    html =
      render_inbox(
        [inbox_decision("dec-overview-only")],
        :all,
        %{total: 701, open: 503, awaiting: 503, blocking: 401, awaiting_blocking: 401}
      )

    assert html =~ ~s(class="filter-row" aria-label="Command filters" data-count-scope="commands")
    assert html =~ ~s(data-count-label="All")
    assert html =~ ~r/All\s+<span class="count num">701<\/span>/
    assert html =~ ~r/Open\s+<span class="count num">503<\/span>/
    assert html =~ ~r/Blocking\s+<span class="count num">401<\/span>/
    assert html =~ "Commands inbox"
    assert html =~ "Resolved"
    refute html =~ ~r/>Undelivered\s+<span class="count num">/
    refute html =~ ~r/>Supervisor\s+<span class="count num">/
    refute html =~ ~r/>Superseded\s+<span class="count num">/
  end

  test "renders a writable canonical answer form without a confirmation footer" do
    decision = action_decision(reversibility: :irreversible, kind: "destructive_op")

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-submit="answer-decision")
    assert html =~ ~s(name="answer[choice]")
    refute html =~ "Persisted before dispatch"
    refute html =~ "Durable command"
    refute html =~ "Answer this Command"
    refute html =~ "Rationale"
    refute html =~ "I understand this Command is irreversible or destructive."
    refute html =~ "Choose an option"
    assert html =~ ">Decision</button>"
  end

  test "renders recommended card-face choices with Decision and Defer-to-Executor actions" do
    decision = action_decision([])

    html =
      render_component(&DecisionAction.decision_action/1, %{
        decision: decision,
        state: %{},
        writable: true,
        compact: true
      })

    assert html =~ ~s(class="decision-action compact")
    assert html =~ ~s(value="option:ship")
    assert html =~ ~s(checked)
    assert html =~ "Recommended"
    assert html =~ ~s(phx-submit="answer-decision")
    assert html =~ ~s(phx-click="defer-decision")
    assert html =~ "Defer to Executor"
    assert html =~ ">Decision</button>"
  end

  test "free-form attention offers a dismiss alongside the response form" do
    decision = action_decision(options: [], recommendation: nil)

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-click="dismiss-decision")
    refute html =~ ">Acknowledge</button>"
    assert html =~ ~s(phx-submit="answer-decision")
  end

  test "optioned command offers a dismiss alongside the choice list" do
    decision = action_decision([])

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-click="dismiss-decision")
    refute html =~ ">Acknowledge</button>"
  end

  test "blocking legacy attention offers an operator dismiss X" do
    decision = action_decision(blocking: true, legacy_attention: %{slug: "scope-question", topic: "ticket.1.attention"})

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-click="dismiss-decision")
    assert html =~ ~s(aria-label="Dismiss blocker")
    assert html =~ ">×</button>"
  end

  test "any open command offers a dismiss control" do
    # The store still refuses an agent-filed blocking Command with no legacy
    # attention, but the UI offers the control so the operator can attempt it;
    # the store answers with the honest refusal.
    decision = action_decision(blocking: true, legacy_attention: nil)

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

    assert html =~ ~s(phx-click="dismiss-decision")
  end

  test "command footer renders defer, dismiss and submit for an open command" do
    blocking =
      action_decision(blocking: true, legacy_attention: %{slug: "scope-question", topic: "ticket.1.attention"})

    free_form = action_decision(options: [], recommendation: nil)

    for decision <- [blocking, free_form] do
      html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})

      buttons = html |> Floki.parse_document!() |> Floki.find(".decision-action-buttons button")
      assert length(buttons) == 3
    end
  end

  test "dismissed historic card offers a change choice answer without another dismiss" do
    decision = action_decision(decision_status: :dismissed)

    html =
      render_component(&DecisionAction.decision_action/1, %{
        decision: decision,
        state: %{},
        writable: true,
        compact: true
      })

    assert html =~ ~s(phx-submit="answer-decision")
    assert html =~ "Change choice"
    refute html =~ ~s(phx-click="defer-decision")
  end

  test "deferred card stays answerable with a distinct Executor badge" do
    decision =
      action_decision(decision_status: :deferred)
      |> Map.merge(%{
        created_at: ~U[2026-07-30 12:00:00Z],
        ticket: %{identifier: "1380", title: "Deferred decision", url: nil},
        context: %{short: nil, long_markdown: nil},
        question: "Which release train should ship?",
        urgency: :normal,
        source: %{agent_id: nil},
        blocking: false,
        artifacts: [],
        revision_sequence: 0,
        superseded?: false,
        provenance: nil
      })

    html = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true, compact: true})

    assert html =~ ~s(phx-submit="answer-decision")
    assert html =~ "Change choice"
    assert html =~ ~s(phx-click="defer-decision")
    assert html =~ "Notify Executor again"

    card_html =
      render_component(&DecisionCard.decision_card/1, %{
        decision: decision,
        writable: true,
        now: ~U[2026-07-30 12:00:00Z]
      })

    assert card_html =~ "Deferred to Executor"
  end

  test "renders canonical answer evidence and gates failed-delivery retry by writable mode" do
    answer = %{
      action_id: "act-dashboard",
      decision_version: 1,
      selected_option_id: "ship",
      custom_response: nil,
      rationale: "Checks are green",
      actor: %{kind: :operator, id: "dashboard"},
      accepted_at: ~U[2026-07-12 13:00:00Z]
    }

    decision =
      action_decision(
        decision_status: :decided,
        delivery_status: :failed,
        lifecycle: :delivery_failed,
        answer: answer,
        retryable: true,
        failure_reason: "target_agent_unavailable"
      )

    writable = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: true})
    readonly = render_component(&DecisionAction.decision_action/1, %{decision: decision, state: %{}, writable: false})

    assert writable =~ "Checks are green"
    assert writable =~ "Delivery failed"
    assert writable =~ ~s(phx-click="retry-decision")
    assert writable =~ "Target agent unavailable"
    refute readonly =~ ~s(phx-click="retry-decision")
    refute readonly =~ ~s(phx-submit="answer-decision")
  end

  test "labels executor answers distinctly while retaining supervisor answer labels" do
    operator = inbox_decision("dec-operator-answer", decision_status: :decided, answer: action_answer(:operator))
    executor = inbox_decision("dec-executor-answer", decision_status: :decided, answer: action_answer(:executor))
    supervisor = inbox_decision("dec-supervisor-answer", decision_status: :decided, answer: action_answer(:supervisor))

    operator_card =
      render_component(&DecisionCard.decision_card/1, %{
        decision: operator,
        writable: false,
        now: ~U[2026-07-12 13:00:00Z]
      })

    executor_card =
      render_component(&DecisionCard.decision_card/1, %{
        decision: executor,
        writable: false,
        now: ~U[2026-07-12 13:00:00Z]
      })

    supervisor_card =
      render_component(&DecisionCard.decision_card/1, %{
        decision: supervisor,
        writable: false,
        now: ~U[2026-07-12 13:00:00Z]
      })

    operator_history = render_history([operator])
    executor_history = render_history([executor])
    supervisor_history = render_history([supervisor])

    executor_latency =
      render_component(&DecisionLatency.decision_latency/1, %{
        latency: %{status: :available, snapshot: %{actor: "executor"}}
      })

    assert operator_card =~ "Operator answer"
    refute operator_card =~ "Executor answer"
    refute operator_card =~ "Supervisor answer"
    assert executor_card =~ "Executor answer"
    refute executor_card =~ "Operator answer"
    refute executor_card =~ "Supervisor answer"
    assert supervisor_card =~ "Supervisor answer"
    refute supervisor_card =~ "Operator answer"
    refute supervisor_card =~ "Executor answer"
    assert operator_history =~ "Operator answer"
    assert executor_history =~ "Executor answer"
    assert supervisor_history =~ "Supervisor answer"
    assert executor_latency =~ "Executor"
  end

  test "renders canonical OCC-9 latency with accessible labels and honest pending fields" do
    latency = %{
      status: :available,
      snapshot: %{
        request_to_decision_ms: 250,
        decision_to_dispatch_ms: 1_500,
        dispatch_to_delivery_ms: nil,
        delivery_to_ack_ms: nil,
        blocked_time_ms: 1_750,
        reminder_count: 2,
        attention_count: 3,
        actor: "human",
        revised: true
      }
    }

    html = render_component(&DecisionLatency.decision_latency/1, %{latency: latency})

    assert html =~ ~s(aria-labelledby="decision-latency-title")
    assert html =~ "Request to Command"
    assert html =~ "250 ms"
    assert html =~ "Command to dispatch"
    assert html =~ "1.5 s"
    assert html =~ "Dispatch to delivery"
    assert html =~ "Pending"
    assert html =~ "Blocked time"
    assert html =~ "2 reminders"
    assert html =~ "3 attentions"
    assert html =~ "Human"
    assert html =~ "Revised"
  end
end
