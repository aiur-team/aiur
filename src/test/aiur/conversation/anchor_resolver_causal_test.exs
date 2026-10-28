Code.require_file("journal_support.exs", __DIR__)

defmodule Aiur.Conversation.AnchorResolverCausalTest do
  use ExUnit.Case, async: false
  alias Aiur.Conversation.{AnchorResolver, History, Ingest, Ref, TestSupport}
  alias Aiur.Events.Exchange
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

  test "matching Executor merge and unmatched worker persist different precision for the same event", ctx do
    command(ctx, ctx.worker, "gh pr merge 43", "Merged")
    command(ctx, Ref.executor(), "gh pr merge 42 --squash", "Merged")
    publish(ctx, "pr.merged", %{action: "closed", pr: %{"number" => 42, "head" => %{"sha" => "abc"}}, timestamp: ctx.now})
    assert [%{"precision" => "observed", "pos" => 2}] = anchors(ctx.worker)
    assert [%{"precision" => "causal", "pos" => 1, "kind" => "pr_merged"} = executor] = anchors(Ref.executor())
    assert executor["subject_ref"]["pr_number"] == 42
    assert executor["event"]["event_id"] == 1
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
