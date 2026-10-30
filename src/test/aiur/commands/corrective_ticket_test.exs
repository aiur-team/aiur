defmodule Aiur.Commands.CorrectiveTicketTest do
  use ExUnit.Case, async: true

  alias Aiur.Commands.{CorrectiveTicket, CorrectiveTicketBody}
  alias Aiur.{Decision, DecisionAnswer, DecisionRevision, Issue}

  setup do
    now = DateTime.utc_now()
    old = struct(DecisionAnswer, action_id: "old", custom_response: "keep blue")
    answer = struct(DecisionAnswer, action_id: "override-1", custom_response: "use green")
    revision = struct(DecisionRevision, action_id: "override-1", prior_action_id: "old", answer: answer, recorded_at: now)
    record = %{action_id: "override-1", route: :corrective_ticket, state: :queued, ticket: %{identifier: "50"}}
    decision = struct(Decision, decision_id: "command", ticket: %{identifier: "50"}, question: "Which colour?", short_label: "Colour", answer: old, revisions: [revision], overrides: [record])
    {:ok, storage} = Agent.start_link(fn -> %{tickets: [], comments: %{}, creates: 0, timeout: false} end)

    opts = [
      issue_closure: fn identifier, _ -> {:ok, %{open?: identifier == "70"}} end,
      pull_request: fn
        "50" -> {:ok, %{merged?: true, number: 60, merge_commit_sha: "source-merge"}}
        "70" -> {:ok, nil}
      end,
      issues: fn
        ["50"] -> {:ok, [%Issue{labels: ["feature:colour", "area:ui", "priority:2", "complexity:4", "agent:done"]}]}
        ["70"] -> {:ok, [%Issue{state: "todo"}]}
      end,
      find: fn marker, _opts -> {:ok, Agent.get(storage, &Enum.find(&1.tickets, fn ticket -> String.contains?(ticket["body"], marker) end))} end,
      create: fn attrs, opts ->
        assert opts[:caller] == "command_override_create"
        ticket = %{"number" => 70, "url" => "https://example.test/70", "body" => attrs.body, "labels" => attrs.labels, "title" => attrs.title}

        Agent.get_and_update(storage, fn state ->
          result = if state.timeout, do: {:error, :outcome_unknown}, else: {:ok, ticket}
          {result, %{state | tickets: [ticket | state.tickets], creates: state.creates + 1}}
        end)
      end,
      comments: fn target -> {:ok, Agent.get(storage, &Map.get(&1.comments, target, []))} end,
      comment: fn target, body -> Agent.update(storage, &put_in(&1, [:comments, target], [%{body: body} | Map.get(&1.comments, target, [])])) end
    ]

    %{decision: decision, record: record, storage: storage, opts: opts}
  end

  test "builds the corrective contract and copies only dispatch-safe labels", ctx do
    assert {:ok, [{:override_corrective_ticket, data}]} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, ctx.opts)
    assert data.ticket.identifier == "70"
    assert data.pr_number == 60
    assert data.merge_commit_sha == "source-merge"
    assert [ticket] = Agent.get(ctx.storage, & &1.tickets)
    assert ticket["title"] == "Override for #50: Colour"
    assert ticket["labels"] == ["feature:colour", "area:ui", "priority:2", "agent:todo", "complexity:2"]

    for text <- ["Which colour?", "keep blue", "use green", "Merged PR: #60", "source-merge", "override-1", "Change the merged behaviour to match the new answer through a new PR."] do
      assert String.contains?(ticket["body"], text)
    end

    assert Map.keys(Agent.get(ctx.storage, & &1.comments)) |> Enum.sort() == ["50", "60"]
    assert CorrectiveTicketBody.labels(["complexity:1", "agent:done"]) == ["agent:todo", "complexity:1"]
  end

  test "replaying before the link fact is durable creates exactly one ticket and link per target", ctx do
    assert {:ok, first} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, ctx.opts)
    assert {:ok, ^first} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, ctx.opts)
    assert Agent.get(ctx.storage, & &1.creates) == 1
    assert Agent.get(ctx.storage, &Enum.map(&1.comments, fn {_target, comments} -> length(comments) end)) == [1, 1]
  end

  test "unknown create outcome is reconciled by marker before another create", ctx do
    Agent.update(ctx.storage, &%{&1 | timeout: true})
    assert {:error, :outcome_unknown} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, ctx.opts)
    assert {:ok, [{:override_corrective_ticket, %{ticket: %{identifier: "70"}}}]} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, ctx.opts)
    assert Agent.get(ctx.storage, & &1.creates) == 1
  end

  test "incomplete lookup never authorizes a new ticket", ctx do
    opts = Keyword.put(ctx.opts, :find, fn _, _ -> {:error, :incomplete_issue_lookup} end)
    assert {:error, :incomplete_issue_lookup} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, opts)
    assert Agent.get(ctx.storage, & &1.creates) == 0
  end

  test "unmerged and unknown source PR evidence never creates a ticket", ctx do
    for result <- [{:ok, nil}, {:ok, %{merged?: false}}, {:error, :unavailable}] do
      opts = Keyword.put(ctx.opts, :pull_request, fn "50" -> result end)
      assert {:error, _reason} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, opts)
    end

    assert Agent.get(ctx.storage, & &1.creates) == 0
  end

  test "a later override adopts the unrecorded prior corrective ticket", ctx do
    assert {:ok, _first} = CorrectiveTicket.reconcile(ctx.decision, ctx.record, ctx.opts)
    first = hd(ctx.decision.revisions)
    second = %{first | action_id: "override-2", prior_action_id: first.action_id, recorded_at: DateTime.add(first.recorded_at, 3_600)}
    record = %{ctx.record | action_id: second.action_id}
    decision = %{ctx.decision | revisions: [first, second], overrides: [ctx.record, record]}
    find = ctx.opts[:find]

    opts =
      Keyword.put(ctx.opts, :find, fn marker, lookup_opts ->
        {:ok, cutoff, _offset} = DateTime.from_iso8601(lookup_opts[:since])
        if DateTime.compare(first.recorded_at, cutoff) == :lt, do: {:ok, nil}, else: find.(marker, lookup_opts)
      end)

    assert {:ok, [origin, current]} = CorrectiveTicket.reconcile(decision, record, opts)
    assert {:override_corrective_ticket, %{ticket: %{identifier: "70"} = ticket, action_id: "override-1"}} = origin
    assert {:override_corrective_ticket, %{ticket: ^ticket, action_id: "override-2"}} = current
    refute Map.has_key?(ticket, :origin_action_id)
    assert Agent.get(ctx.storage, & &1.creates) == 1
  end

  test "only the corrective PR merge proves implementation", ctx do
    record = Map.put(ctx.record, :corrective_ticket, %{identifier: "70"})
    assert {:ok, []} = CorrectiveTicket.reconcile(ctx.decision, record, ctx.opts)
    opts = Keyword.put(ctx.opts, :pull_request, fn "70" -> {:ok, %{merged?: true, number: 80, merge_commit_sha: "corrected-merge"}} end)
    assert {:ok, [{:override_corrective_implemented, %{action_id: "override-1", pr_number: 80, merge_commit_sha: "corrected-merge"}}]} = CorrectiveTicket.reconcile(ctx.decision, record, opts)
    assert Agent.get(ctx.storage, & &1.creates) == 0
  end
end
