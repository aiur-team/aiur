defmodule Aiur.Events.BranchForcePushTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.AgentList.Renderer.{EventLine, EventPhrases}
  alias Aiur.AgentRunner.EventsDigest
  alias Aiur.Events.{BranchRefStore, LsRemoteTicker, Publisher, SubscriptionStore}
  alias Aiur.Opencode.EventRow
  alias Aiur.Orchestrator.AutoSubscriptions

  @ref "refs/heads/aiur/93759-rewrite"
  @topic "ticket.93759.branch.force-push"
  @old String.duplicate("a", 40)
  @new String.duplicate("b", 40)

  setup do
    :ok = Aiur.TestSupport.ensure_runtime_children_running()
    :ok = BranchRefStore.reset()
    on_exit(fn -> BranchRefStore.reset() end)
    :ok
  end

  for status <- ["behind", "diverged", "ahead", "identical", 404, 500, :budget_hold, :raise] do
    @status status
    test "compare #{inspect(status)} classifies subscribed moves without blocking polling" do
      :ok = subscribe()
      {pid, refs} = start_ticker(response(@status))
      Agent.update(refs, fn _ -> %{@ref => @new} end)
      tick(pid)
      receive_barrier({:published, "ticket.93759.branch.push", %{previous_sha: @old, sha: @new}})
      receive_barrier({:compare, task, request})
      assert request.url == "https://api.github.com/repos/owner/repo/compare/#{@old}...#{@new}?per_page=1"
      assert request.caller == "ticket_branch_rewrite"
      monitor = Process.monitor(task)
      send(task, :finish_compare)
      receive_barrier({:DOWN, ^monitor, :process, ^task, _})
      assert Process.alive?(pid)

      if rewrite?(@status) do
        receive_barrier({:published, @topic, payload})
        assert payload.previous_sha == @old
        assert payload.ref == @ref
        assert payload.sha == @new
        assert payload.compare_status == expected_status(@status)
        assert payload.previous_missing == missing?(@status)
        assert payload.superseded == false
        digest = EventsDigest.render([Map.merge(payload, %{topic: @topic, id: 1})], "1")
        assert digest =~ "previous_missing=#{missing?(@status)}"
        assert digest =~ "compare_status=#{inspect(expected_status(@status))}"
      else
        refute_received {:published, @topic, _}
      end

      refute_received {:published, _, _}
    end
  end

  test "unsubscribed refs and subscribed new refs never call compare" do
    {pid, refs} = start_ticker(response("diverged"))
    :ok = subscribe("ticket.93759.branch.push")
    Agent.update(refs, fn _ -> %{@ref => @new} end)
    tick(pid)
    assert_no_compare_tasks(pid)
    receive_barrier({:published, "ticket.93759.branch.push", %{previous_sha: @old}})
    :ok = subscribe()
    Agent.update(refs, fn _ -> %{} end)
    tick(pid)
    Agent.update(refs, fn _ -> %{@ref => @new} end)
    tick(pid)
    assert_no_compare_tasks(pid)
    receive_barrier({:published, "ticket.93759.branch.push", %{previous_sha: nil}})
    refute_received {:compare, _, _}
  end

  test "delayed verdict identifies a superseded transition" do
    :ok = subscribe()
    {pid, refs} = start_ticker(response("diverged"))
    Agent.update(refs, fn _ -> %{@ref => @new} end)
    tick(pid)
    receive_barrier({:compare, task, _})
    :ok = SubscriptionStore.remove_subscription("rewrite-#{inspect(self())}", @topic)
    Agent.update(refs, fn _ -> %{@ref => String.duplicate("c", 40)} end)
    tick(pid)
    send(task, :finish_compare)
    receive_barrier({:published, @topic, %{sha: @new, superseded: true} = payload})
    assert EventsDigest.render([Map.merge(payload, %{topic: @topic, id: 1})], "1") =~ "superseded=true"
  end

  test "compare failures increment the error counter" do
    parent = self()
    handler = "rewrite-test-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:aiur, :events, :branch_rewrite, :error], fn _, measurements, _, _ -> send(parent, {:error_count, measurements.count}) end, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = subscribe()
    {pid, refs} = start_ticker(response(500))
    Agent.update(refs, fn _ -> %{@ref => @new} end)
    tick(pid)
    receive_barrier({:compare, task, _})
    send(task, :finish_compare)
    receive_barrier({:error_count, 1})
  end

  test "publisher routes a rewrite to dependent store and critical digest" do
    parent = self()
    id = "rewrite-dependent-#{System.unique_integer([:positive])}"

    SubscriptionStore.set_enqueue_fn(fn target, event ->
      send(parent, {:enqueued, target, event})
      :ok
    end)

    on_exit(fn ->
      SubscriptionStore.stop(id)
      SubscriptionStore.set_enqueue_fn(nil)
    end)

    :ok = SubscriptionStore.attach(id)
    :ok = SubscriptionStore.add_subscription(id, @topic, "blocker:auto")
    publisher = fn topic, payload, opts -> Publisher.publish(topic, payload, Keyword.put(opts, :bypass_contamination, true)) end
    {pid, refs} = start_ticker(response("diverged"), publisher)
    Agent.update(refs, fn _ -> %{@ref => @new} end)
    tick(pid)
    receive_barrier({:compare, task, _})
    send(task, :finish_compare)
    receive_barrier({:enqueued, ^id, %{topic: @topic, previous_sha: @old} = event})
    assert AutoSubscriptions.blocker_critical_digest?(%{category: :coordination_event, event_type: :events_digest, body: %{events: [event]}}, ["93759"])
    assert EventsDigest.render([event], id) =~ "force-pushed #{@ref}"
  end

  test "renderers name force-pushes without previous SHA" do
    assert EventPhrases.publish_event_phrase("branch.force-push", %{ref: @ref}) == {"force-pushed", ""}
    assert EventLine.cross_receive_verb("branch.force-push") == "force-pushed"
    assert EventRow.from(%{kind: :receive, topic: @topic, body: %{ref: @ref}}, "1") == "> 📬 Ticket 93759 force-pushed its branch"
    assert EventLine.describe_event(:receive, "1", "93759", "branch.force-push", %{ref: @ref}) == {"← 93759: force-pushed", ""}
  end

  defp subscribe(topic \\ @topic) do
    id = "rewrite-#{inspect(self())}"
    :ok = SubscriptionStore.attach(id)
    on_exit({:subscription_store, id}, fn -> SubscriptionStore.stop(id) end)
    SubscriptionStore.add_subscription(id, topic, "blocker:auto")
  end

  defp assert_no_compare_tasks(pid) do
    supervisor = :sys.get_state(pid).compare_opts[:task_supervisor]
    assert Task.Supervisor.children(supervisor) == []
  end

  defp rewrite?(status), do: status in ["behind", "diverged", 404]
  defp expected_status(404), do: "unknown"
  defp expected_status(status), do: status
  defp missing?(404), do: true
  defp missing?(_), do: false

  defp response(status) when is_binary(status), do: {:ok, %{status: 200, body: %{"status" => status}}}
  defp response(status) when is_integer(status), do: {:ok, %{status: status, body: %{}}}
  defp response(:budget_hold), do: {:error, {:aiur, :locally_held, %{}}}
  defp response(:raise), do: :raise

  defp start_ticker(response, publisher \\ nil) do
    parent = self()
    supervisor = start_supervised!({Task.Supervisor, []})
    refs = start_supervised!({Agent, fn -> %{@ref => @old} end})

    request_fun = fn request ->
      send(parent, {:compare, self(), request})
      receive do: (:finish_compare -> :ok)
      if response == :raise, do: raise("compare failed"), else: response
    end

    publisher = publisher || fn topic, payload, _opts -> send(parent, {:published, topic, payload}) end

    pid =
      start_supervised!(
        {LsRemoteTicker,
         name: nil, repo: "owner/repo", publisher: publisher, request_fun: request_fun, task_supervisor: supervisor, start_paused?: true, ls_remote_fun: fn _, _ -> {:ok, Agent.get(refs, & &1)} end}
      )

    tick(pid)
    refute_received {:published, _, _}
    {pid, refs}
  end

  defp tick(pid) do
    send(pid, :tick)
    :sys.get_state(pid)
  end
end
