defmodule Aiur.OrchestratorFirehoseTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.GitHub.Connectivity
  alias Aiur.GitHub.Listeners
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{CommentPolling, FirehosePolling, TrackerHealth}
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    if is_nil(Process.whereis(Listeners)), do: start_supervised!(Listeners)
    Listeners.reset()
    :ok
  end

  test "repeated DNS failures escalate to an operator-visible connectivity blocker" do
    # WHY (#617): a DNS outage in an agent workspace used to only
    # Logger.warning forever, so the operator never learned agents were
    # wedged. After a sustained streak the firehose path must fire a loud,
    # surfaced alert that an operator can act on.
    :ok = Exchange.subscribe("system.github.connectivity_lost")

    stub = fn _req -> {:error, %Req.TransportError{reason: :nxdomain}} end

    state =
      Enum.reduce(1..Connectivity.escalation_threshold(), %Orchestrator.State{}, fn _i, acc ->
        FirehosePolling.poll(acc, request_fun: stub)
      end)

    # The streak is tracked as a classified :dns break under the firehose source.
    assert {:dns, _count} = state.github_connectivity[:firehose]

    assert_receive {:event, %{topic: "system.github.connectivity_lost"} = event}, 500
    assert event["message"] =~ "DNS"
  end

  test "firehose next poll delay grows with repeated DNS failures" do
    stub = fn _req -> {:error, %Req.TransportError{reason: :nxdomain}} end

    state1 = FirehosePolling.poll(%Orchestrator.State{}, request_fun: stub)
    assert TrackerHealth.github_next_poll_delay_ms(state1) == 1_000

    state2 = FirehosePolling.poll(state1, request_fun: stub)
    assert TrackerHealth.github_next_poll_delay_ms(state2) == 2_000
  end

  test "firehose honors Retry-After on rate-limited responses" do
    stub = fn _req ->
      {:ok, %{status: 429, headers: [{"Retry-After", "7"}], body: %{"message" => "rate limited"}}}
    end

    state = FirehosePolling.poll(%Orchestrator.State{}, request_fun: stub)

    assert {:rate_limited, 1} = state.github_connectivity[:firehose]
    assert TrackerHealth.github_next_poll_delay_ms(state) == 7_000
  end

  test "firehose honors X-Poll-Interval on successful responses" do
    stub = fn _req ->
      {:ok, %{status: 200, headers: [{"ETag", ~s("e")}, {"X-Poll-Interval", "13"}], body: []}}
    end

    state = FirehosePolling.poll(%Orchestrator.State{}, request_fun: stub)

    assert state.github_connectivity[:firehose] == nil
    assert TrackerHealth.github_next_poll_delay_ms(state) == 13_000
  end

  test "comments poller honors Retry-After on rate-limited responses" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok, %{status: 429, headers: [{"Retry-After", "9"}], body: %{"message" => "rate limited"}}}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    state = %Orchestrator.State{
      running: %{
        "issue-42" => %{
          identifier: "42",
          issue: %Issue{id: "issue-42", state: "in-progress", identifier: "42"},
          control: %{status: :working}
        }
      }
    }

    next =
      CommentPolling.poll_github_comments(state,
        repo: "owner/repo",
        request_fun: request_fun,
        review_issue_fetcher: fn ["human-review", "merging", "rework", "ci-wait"] -> {:ok, []} end
      )

    assert {:rate_limited, 1} = next.github_connectivity[:comments]
    assert TrackerHealth.github_next_poll_delay_ms(next) == 9_000
  end

  test "a recovering poll clears the connectivity streak" do
    fail = fn _req -> {:error, %Req.TransportError{reason: :nxdomain}} end

    ok = fn req ->
      page = request_page(req)
      body = if page == "1", do: [], else: []
      {:ok, %{status: 200, headers: [{"ETag", ~s("e")}], body: body}}
    end

    state = FirehosePolling.poll(%Orchestrator.State{}, request_fun: fail)
    assert {:dns, 1} = state.github_connectivity[:firehose]
    assert TrackerHealth.github_next_poll_delay_ms(state) == 1_000

    recovered = FirehosePolling.poll(state, request_fun: ok)
    assert recovered.github_connectivity[:firehose] == nil
    assert TrackerHealth.github_next_poll_delay_ms(recovered) == 60_000
  end

  # #2354 metric: every successful firehose tick reports how many pages were
  # fetched and whether the previous watermark was reachable, so a window that
  # is silently truncating is observable rather than invisible.
  defp request_page(%{url: url}) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("page")
  end
end
