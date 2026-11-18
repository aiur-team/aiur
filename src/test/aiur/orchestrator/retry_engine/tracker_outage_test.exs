defmodule Aiur.Orchestrator.RetryEngine.TrackerOutageTest do
  # Global event doubles require synchronous cases.
  use Aiur.TestSupport

  alias Aiur.AgentRunner.TrackerOutage
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.RetryEngine.Scheduling
  alias Aiur.Orchestrator.State

  # A GitHub 504 used to cost the ticket its claim after three retry polls while
  # its workspace still held the work, and a worker whose between-turn refresh
  # hit one exited. An outage says nothing about the ticket: keep both and wait.
  @gateway_timeout {:github, :http, %{status: 504}}
  @t0 1_000
  @minute 60 * 1_000

  setup do
    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)
  end

  describe "retry poll" do
    test "keeps the claim through a long outage and raises one attention after the threshold" do
      {issue_id, identifier} = {"issue-outage", "repo#outage"}
      outage_topic = TrackerOutage.topic(identifier)
      :ok = Exchange.subscribe(outage_topic)
      :ok = Exchange.subscribe("orchestrator.claim_released")

      state = %State{claimed: MapSet.new([issue_id])}
      metadata = %{identifier: identifier, workspace_path: "/ws/outage", worker_host: "nuc"}

      {state, metadata} =
        Enum.reduce([0, 2, 5, 9, 14], {state, metadata}, fn minute, {state, metadata} ->
          poll_failure(state, issue_id, Map.put(metadata, :now_ms, @t0 + minute * @minute))
        end)

      assert MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.released_claims, issue_id)
      refute_receive {:event, %{topic: "orchestrator.claim_released"}}, 50
      refute_receive {:event, %{topic: ^outage_topic}}, 50
      assert metadata.workspace_path == "/ws/outage"
      assert metadata.tracker_outage.failures == 5

      {state, metadata} = poll_failure(state, issue_id, Map.put(metadata, :now_ms, @t0 + 16 * @minute))
      assert_receive {:event, %{topic: ^outage_topic} = alert}, 1_000
      assert alert["message"] =~ "cannot reach GitHub for 16 min (6 failed tracker calls"

      {state, _metadata} = poll_failure(state, issue_id, Map.put(metadata, :now_ms, @t0 + 30 * @minute))
      refute_receive {:event, %{topic: ^outage_topic}}, 50
      assert MapSet.member?(state.claimed, issue_id)
      cancel(state, issue_id)
    end

    test "a refusal after an outage still gets its full three polls before the release" do
      issue_id = "issue-outage-then-403"
      state = %State{claimed: MapSet.new([issue_id])}
      metadata = %{identifier: "repo#then-403", now_ms: @t0}

      {state, metadata} =
        Enum.reduce(1..4, {state, metadata}, fn _n, {state, metadata} -> poll_failure(state, issue_id, metadata) end)

      {state, metadata} = poll_failure(state, issue_id, metadata, {:github_api_status, 403})
      {state, _metadata} = poll_failure(state, issue_id, metadata, {:github_api_status, 403})
      assert MapSet.member?(state.claimed, issue_id)
      cancel(state, issue_id)
    end

    test "a refusal still releases the claim after three polls" do
      issue_id = "issue-refused"
      state = %State{claimed: MapSet.new([issue_id])}
      metadata = %{identifier: "repo#refused"}

      {state, metadata} = poll_failure(state, issue_id, metadata, {:github_api_status, 403})
      {state, metadata} = poll_failure(state, issue_id, metadata, {:github_api_status, 403})
      state = RetryEngine.handle_retry_poll_failure(state, issue_id, 1, metadata, {:github_api_status, 403})

      refute MapSet.member?(state.claimed, issue_id)
      assert %{cause: :tracker_retry_exhausted} = state.released_claims[issue_id]
    end
  end

  describe "a live worker's state refresh" do
    test "waits out an outage with backoff and keeps the session" do
      issue = %Aiur.Issue{id: "issue-refresh", identifier: "repo#refresh", state: "in-progress"}
      refreshed = %{issue | state: "in-progress"}
      {:ok, replies} = Agent.start_link(fn -> [{:error, @gateway_timeout}, {:error, {:github_api_status, 502}}, {:ok, [refreshed]}] end)
      fetcher = fn ["issue-refresh"] -> Agent.get_and_update(replies, fn [reply | rest] -> {reply, rest} end) end

      assert {:ok, [^refreshed]} = TrackerOutage.refresh(issue, fetcher, sleep_fun: &send(self(), {:slept, &1}))
      assert_received {:slept, 10_000}
      assert_received {:slept, 20_000}
    end

    test "raises one attention once the outage passes the threshold" do
      issue = %Aiur.Issue{id: "issue-long", identifier: "repo#long", state: "in-progress"}
      topic = TrackerOutage.topic(issue.identifier)
      :ok = Exchange.subscribe(topic)
      {:ok, clock} = Agent.start_link(fn -> @t0 end)
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fetcher = fn _ids ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) < 6, do: {:error, @gateway_timeout}, else: {:ok, [issue]}
      end

      opts = [sleep_fun: fn _ms -> Agent.update(clock, &(&1 + 4 * @minute)) end, now_ms_fun: fn -> Agent.get(clock, & &1) end]

      assert {:ok, [^issue]} = TrackerOutage.refresh(issue, fetcher, opts)
      assert_receive {:event, %{topic: ^topic} = alert}, 1_000
      assert alert["message"] =~ "for 16 min (5 failed tracker calls"
      refute_receive {:event, %{topic: ^topic}}, 50
    end

    test "returns a refusal at once" do
      issue = %Aiur.Issue{id: "issue-403", identifier: "repo#403", state: "in-progress"}

      assert {:error, {:github_api_status, 403}} =
               TrackerOutage.refresh(issue, fn _ids -> {:error, {:github_api_status, 403}} end, sleep_fun: fn _ms -> flunk("slept on a refusal") end)
    end
  end

  # Fails one retry poll, then pops the scheduled retry as its timer would.
  defp poll_failure(state, issue_id, metadata, reason \\ @gateway_timeout) do
    state = RetryEngine.handle_retry_poll_failure(state, issue_id, 1, metadata, reason)
    %{retry_token: token, timer_ref: timer} = state.retry_attempts[issue_id]
    Process.cancel_timer(timer)
    {:ok, _attempt, popped, state} = Scheduling.pop_retry_attempt_state(state, issue_id, token)
    {state, Map.put(popped, :now_ms, metadata[:now_ms])}
  end

  defp cancel(state, issue_id) do
    case state.retry_attempts[issue_id] do
      %{timer_ref: timer} -> Process.cancel_timer(timer)
      nil -> :ok
    end
  end
end
