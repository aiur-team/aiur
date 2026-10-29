Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.AnchorResolverCausalTest do
  use ExUnit.Case, async: false
  alias Aiur.Conversation.{AnchorResolver, History, Ingest, Ref, TestSupport}
  alias Aiur.Events.{BranchRefStore, Exchange, LsRemoteTicker, Publisher}
  alias Aiur.Orchestrator.TrackedSet
  import TestSupport

  setup context do
    ctx = TestSupport.setup(context)
    opts = Application.fetch_env!(:aiur, :conversation_journal) |> Keyword.put(:store, Aiur.Conversation.Store)
    Application.put_env(:aiur, :conversation_journal, opts)
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "I_causal", "number" => 6628}, {"aiur-team", "aiur"}, {"aiur-team", "aiur"})
    {:ok, worker} = Ref.worker(identity)
    exchange = start_supervised!({Exchange, []})
    resolver = start_supervised!({AnchorResolver, name: nil, exchange: exchange, pubsub: ctx.pubsub})
    Map.merge(ctx, %{worker: worker, identity: identity, exchange: exchange, resolver: resolver})
  end

  test "worker push picks the causal command ahead of a newer observed message", ctx do
    command(ctx, ctx.worker, "git push", "1234567..abcdef1 feature -> feature")
    publish(ctx, "branch.push", %{sha: "abcdef1234567890", ref: "refs/heads/feature"})
    assert [%{"precision" => "causal", "pos" => 1, "placement" => "at"}] = anchors(ctx.worker)
    refute File.exists?(ctx.dir)
  end

  test "real ls-remote publish carries trusted identity into the resolver", ctx do
    :ok = Aiur.TestSupport.ensure_runtime_children_running()
    :ok = BranchRefStore.reset()
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = %Aiur.Issue{id: "issue-6628", identifier: "6628", tracker_identity: ctx.identity}
    tracked_state = %Aiur.Orchestrator.State{running: %{"issue-6628" => %{identifier: "6628", issue: issue}}}
    assert tracked_state == TrackedSet.refresh(tracked_state)

    on_exit(fn ->
      Publisher.set_tracked_fn(&Aiur.Orchestrator.issue_tracked?/1)
      TrackedSet.reset([])
      BranchRefStore.reset()
    end)

    owner = self()
    global_resolver = start_supervised!({AnchorResolver, name: nil, exchange: Aiur.Events.exchange_server(), pubsub: ctx.pubsub}, id: :global_exchange_resolver)
    assert "ticket.*.branch.push" in Exchange.bindings_for(global_resolver)
    :ok = Aiur.Events.subscribe("ticket.6628.branch.push")
    {:ok, refs} = Agent.start_link(fn -> %{"refs/heads/aiur/6628" => "first"} end)

    {:ok, ticker} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: fn _remote, _pattern -> {:ok, Agent.get(refs, & &1)} end,
        publisher: fn topic, payload, opts ->
          result = Aiur.Events.publish(topic, payload, opts)
          send(owner, {:ticker_publish, topic, Keyword.get(opts, :identity), result})
          result
        end,
        repo: "aiur-team/aiur",
        start_paused?: true
      )

    send(ticker, :tick)
    :sys.get_state(ticker)
    command(ctx, ctx.worker, "git push", "b27e56454..abcdef123 HEAD -> aiur/6628")
    Agent.update(refs, &Map.put(&1, "refs/heads/aiur/6628", "abcdef1234567890"))
    send(ticker, :tick)
    :sys.get_state(ticker)
    :sys.get_state(Aiur.Events.exchange_server())
    assert_receive {:ticker_publish, "ticket.6628.branch.push", published_identity, {:ok, _, subscribers}} when subscribers > 0, 1_000
    assert published_identity == ctx.identity
    assert_receive {:event, %{topic: "ticket.6628.branch.push", sha: "abcdef1234567890", ticket_observation: %{status: :joinable, tracker_identity: identity}}}, 1_000
    assert identity == ctx.identity
    :sys.get_state(global_resolver)
    flush(ctx.worker)
    assert Enum.any?(anchors(ctx.worker), &(&1["kind"] == "push" and &1["precision"] == "causal" and &1["pos"] == 1))
    Agent.stop(refs)
  end

  test "matching Executor merge and unmatched worker persist different precision for the same event", ctx do
    command(ctx, ctx.worker, "gh pr merge 43", "Merged")
    command(ctx, Ref.executor(), "gh pr merge 42 --squash", "Merged")
    publish(ctx, "pr.merged", %{action: "closed", pr: %{"number" => 42, "head" => %{"sha" => "abc"}}, timestamp: ctx.now})
    assert [%{"precision" => "observed", "pos" => 2}] = anchors(ctx.worker)
    assert [%{"precision" => "causal", "pos" => 1, "kind" => "pr_merged"} = executor] = anchors(Ref.executor())
    assert executor["subject_ref"]["pr_number"] == 42
    assert executor["event"]["event_id"] == 1
  end

  test "unmatched Executor gets no anchor for worker push or PR events", ctx do
    command(ctx, ctx.worker, "git status", "On branch unrelated")
    command(ctx, Ref.executor(), "git status", "On branch unrelated")

    for {suffix, payload} <- [
          {"branch.push", %{sha: "abcdef1234567890", ref: "refs/heads/feature"}},
          {"pr.opened", %{pr: %{"number" => 42}}},
          {"pr.merged", %{pr: %{"number" => 42}}}
        ] do
      publish(ctx, suffix, payload)
      assert anchors(Ref.executor()) == []
    end

    assert Enum.map(anchors(ctx.worker), &{&1["kind"], &1["precision"], &1["pos"]}) == [
             {"push", "observed", 2},
             {"pr_opened", "observed", 2},
             {"pr_merged", "observed", 2}
           ]
  end

  test "webhook opened PR shape retains its key through the resolver", ctx do
    command(ctx, ctx.worker, "gh pr create --draft", "https://github.com/aiur-team/aiur/pull/42")
    publish(ctx, "pr.opened", %{action: "opened", pr: %{"number" => 42, "head" => %{"sha" => "abc"}}, timestamp: ctx.now})
    assert [%{"precision" => "causal", "pos" => 1, "kind" => "pr_opened"}] = anchors(ctx.worker)
  end

  test "Executor causal anchor upgrades when a later exact source entry arrives", ctx do
    command(ctx, ctx.worker, "git push", "1234567..abcdef1 feature -> feature")
    command(ctx, Ref.executor(), "git push", "1234567..abcdef1 feature -> feature")
    publish(ctx, "branch.push", %{sha: "abcdef1234567890", ref: "refs/heads/feature"}, "late-source")
    assert [%{"precision" => "causal", "pos" => 1}] = anchors(Ref.executor())
    Ingest.append(Ref.executor(), source(), [%{role: "tool", msg_id: "late-source", body: "push", timestamp: ctx.now, payload: %{tool: "push", tool_call_id: "late-source"}}])
    assert :ok = flush(Ref.executor())
    :sys.get_state(ctx.resolver)
    assert :ok = flush(Ref.executor())
    assert [%{"precision" => "exact", "pos" => 3}] = anchors(Ref.executor())
  end

  test "unmatched Executor keeps pending exact provenance without an observed anchor", ctx do
    command(ctx, ctx.worker, "git push", "1234567..abcdef1 feature -> feature")
    command(ctx, Ref.executor(), "git status", "On branch unrelated")
    publish(ctx, "branch.push", %{sha: "abcdef1234567890", ref: "refs/heads/feature"}, "late-source")
    assert anchors(Ref.executor()) == []
    Ingest.append(Ref.executor(), source(), [%{role: "tool", msg_id: "late-source", body: "push", timestamp: ctx.now, payload: %{tool: "push", tool_call_id: "late-source"}}])
    assert :ok = flush(Ref.executor())
    :sys.get_state(ctx.resolver)
    assert :ok = flush(Ref.executor())
    assert [%{"precision" => "exact", "pos" => 3}] = anchors(Ref.executor())
  end

  # Future regression guard: exact precedence already existed; not counted as new causal coverage.
  test "exact provenance wins over a matching causal command", ctx do
    command(ctx, ctx.worker, "git push", "1234567..abcdef1 feature -> feature")
    publish(ctx, "branch.push", %{sha: "abcdef1234567890", ref: "refs/heads/feature"}, "command-1")
    assert [%{"precision" => "exact", "pos" => 1}] = anchors(ctx.worker)
  end

  defp command(ctx, ref, body, output) do
    Ingest.append(ref, source(), [%{role: "command", msg_id: "command-1", body: body, timestamp: ctx.now, payload: %{command: body, output: output, exit_code: 0}}, event(1)])
    assert :ok = flush(ref)
  end

  defp publish(ctx, suffix, payload, tool_id \\ nil) do
    observation = Aiur.TicketObservation.normalize(%{}, identity: ctx.identity, event_id: 1, observed_at: ctx.now, provenance: %{source_event_id: tool_id})
    raw = Map.merge(payload, %{topic: "ticket.6628." <> suffix, ticket_observation: observation})
    Exchange.publish(raw.topic, raw, ctx.exchange)
    :sys.get_state(ctx.resolver)
    assert :ok = flush(ctx.worker)
    if File.exists?(ctx.dir), do: assert(:ok = flush(Ref.executor()))
  end

  defp anchors(ref) do
    assert {:ok, anchors} = History.list_anchors(ref, principal: :internal)
    anchors
  end
end
