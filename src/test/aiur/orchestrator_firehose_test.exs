defmodule Aiur.OrchestratorFirehoseTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.GitHub.Connectivity
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{CommentPolling, TrackerHealth}
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

    :ok
  end

  test "orchestrator preserves the GitHub firehose event watermark" do
    page_1 = ignored_events("burst", 30)
    page_2 = [ignored_event("last-seen")]
    parent = self()

    stub = fn req ->
      page = request_page(req)
      send(parent, {:events_page_requested, page})

      body =
        case page do
          "1" -> page_1
          "2" -> page_2
        end

      {:ok, %{status: 200, headers: [{"ETag", ~s("next-etag")}], body: body}}
    end

    state = %Orchestrator.State{
      events_etag: ~s("previous-etag"),
      events_last_id: "last-seen"
    }

    next = CommentPolling.poll_github_firehose(state, request_fun: stub)

    assert next.events_etag == ~s("next-etag")
    assert next.events_last_id == "burst-1"
    assert_receive {:events_page_requested, "1"}
    assert_receive {:events_page_requested, "2"}
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
        CommentPolling.poll_github_firehose(acc, request_fun: stub)
      end)

    # The streak is tracked as a classified :dns break under the firehose source.
    assert {:dns, _count} = state.github_connectivity[:firehose]

    assert_receive {:event, %{topic: "system.github.connectivity_lost"} = event}, 500
    assert event["message"] =~ "DNS"
  end

  test "firehose next poll delay grows with repeated DNS failures" do
    stub = fn _req -> {:error, %Req.TransportError{reason: :nxdomain}} end

    state1 = CommentPolling.poll_github_firehose(%Orchestrator.State{}, request_fun: stub)
    assert TrackerHealth.github_next_poll_delay_ms(state1) == 1_000

    state2 = CommentPolling.poll_github_firehose(state1, request_fun: stub)
    assert TrackerHealth.github_next_poll_delay_ms(state2) == 2_000
  end

  test "firehose honors Retry-After on rate-limited responses" do
    stub = fn _req ->
      {:ok, %{status: 429, headers: [{"Retry-After", "7"}], body: %{"message" => "rate limited"}}}
    end

    state = CommentPolling.poll_github_firehose(%Orchestrator.State{}, request_fun: stub)

    assert {:rate_limited, 1} = state.github_connectivity[:firehose]
    assert TrackerHealth.github_next_poll_delay_ms(state) == 7_000
  end

  test "firehose honors X-Poll-Interval on successful responses" do
    stub = fn _req ->
      {:ok, %{status: 200, headers: [{"ETag", ~s("e")}, {"X-Poll-Interval", "13"}], body: []}}
    end

    state = CommentPolling.poll_github_firehose(%Orchestrator.State{}, request_fun: stub)

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
        review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, []} end
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

    state = CommentPolling.poll_github_firehose(%Orchestrator.State{}, request_fun: fail)
    assert {:dns, 1} = state.github_connectivity[:firehose]
    assert TrackerHealth.github_next_poll_delay_ms(state) == 1_000

    recovered = CommentPolling.poll_github_firehose(state, request_fun: ok)
    assert recovered.github_connectivity[:firehose] == nil
    assert TrackerHealth.github_next_poll_delay_ms(recovered) == 60_000
  end

  # #2354 metric: every successful firehose tick reports how many pages were
  # fetched and whether the previous watermark was reachable, so a window that
  # is silently truncating is observable rather than invisible.
  test "firehose reports pages fetched and cap status per tick" do
    parent = self()

    telemetry_fun = fn kind, attrs ->
      send(parent, {:firehose_metric, kind, attrs})
      :ok
    end

    stub = fn req ->
      page = request_page(req)
      body = if page == "1", do: Enum.take(ignored_events("m", 30), 5), else: []
      {:ok, %{status: 200, headers: [{"ETag", ~s("metric-etag")}], body: body}}
    end

    state =
      CommentPolling.poll_github_firehose(%Orchestrator.State{},
        request_fun: stub,
        firehose_poll_telemetry_fun: telemetry_fun
      )

    assert_receive {:firehose_metric, :firehose_poll, %{pages_fetched: 1, partial_window?: false, published: 0}}

    assert state.firehose_partial_streak == 0
    assert state.firehose_truncation_alert_active == false
  end

  # #2354 attention: a window that truncates once can be a boot reconciliation
  # or a burst, but a truncating window that keeps truncating is the steady
  # state the old 5-page cap hit on every tick — and that must raise attention
  # rather than pass silently. The attention fires once at the threshold, stays
  # armed on further truncation, and resolves the first tick the window is
  # complete again.
  test "firehose truncation attention fires on a sustained partial window and resolves on a complete one" do
    parent = self()
    counter = :counters.new(1, [:atomics])

    # Every page is saturated with fresh ids so the previous tick's watermark
    # is never reachable — the truncation that used to happen every tick.
    truncated = fn _req ->
      id = :counters.get(counter, 1) + 1
      :counters.add(counter, 1, 1)
      body = Enum.map(1..30, fn n -> ignored_event("gen-#{id}-#{n}") end)
      {:ok, %{status: 200, headers: [{"ETag", ~s("partial-etag")}], body: body}}
    end

    alert_fun = fn topic, opts ->
      send(parent, {:firehose_alert, topic, opts[:needs_attention]})
      :ok
    end

    state =
      Enum.reduce(1..2, %Orchestrator.State{}, fn _i, acc ->
        CommentPolling.poll_github_firehose(acc,
          request_fun: truncated,
          firehose_truncation_alert_fun: alert_fun
        )
      end)

    assert state.firehose_partial_streak == 2
    assert state.firehose_truncation_alert_active
    assert_receive {:firehose_alert, "system.firehose.event_truncation", true}
    refute_receive {:firehose_alert, "system.firehose.event_truncation.resolved", _}, 100

    # One complete window resets the streak and clears the attention.
    complete = fn req ->
      page = request_page(req)
      body = if page == "1", do: [ignored_event("fresh")], else: []
      {:ok, %{status: 200, headers: [{"ETag", ~s("complete-etag")}], body: body}}
    end

    resolved =
      CommentPolling.poll_github_firehose(state,
        request_fun: complete,
        firehose_truncation_alert_fun: alert_fun
      )

    assert resolved.firehose_partial_streak == 0
    assert resolved.firehose_truncation_alert_active == false
    assert_receive {:firehose_alert, "system.firehose.event_truncation.resolved", false}
  end

  # A single truncated tick (for example the boot reconciliation, or a burst
  # that outpaces the window) is disclosed by the metric but does not itself
  # raise the attention; it takes the sustained threshold.
  test "a single truncated firehose window does not raise the attention" do
    truncated = fn _req ->
      {:ok, %{status: 200, headers: [{"ETag", ~s("partial-etag")}], body: ignored_events("one-shot", 30)}}
    end

    state =
      CommentPolling.poll_github_firehose(%Orchestrator.State{},
        request_fun: truncated,
        firehose_truncation_alert_fun: fn _topic, _opts -> :ok end
      )

    assert state.firehose_partial_streak == 1
    assert state.firehose_truncation_alert_active == false
  end

  defp request_page(%{url: url}) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("page")
  end

  defp ignored_events(prefix, count) do
    Enum.map(1..count, &ignored_event("#{prefix}-#{&1}"))
  end

  defp ignored_event(id) do
    %{
      "id" => id,
      "type" => "IssuesEvent",
      "actor" => %{"login" => "noise"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{}
    }
  end
end
