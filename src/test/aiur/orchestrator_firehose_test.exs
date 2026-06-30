defmodule Aiur.OrchestratorFirehoseTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.GitHub.Connectivity
  alias Aiur.Issue
  alias Aiur.Orchestrator
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

    next = Orchestrator.poll_github_firehose_for_test(state, request_fun: stub)

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
        Orchestrator.poll_github_firehose_for_test(acc, request_fun: stub)
      end)

    # The streak is tracked as a classified :dns break under the firehose source.
    assert {:dns, _count} = state.github_connectivity[:firehose]

    assert_receive {:event, %{topic: "system.github.connectivity_lost"} = event}, 500
    assert event["message"] =~ "DNS"
  end

  test "firehose next poll delay grows with repeated DNS failures" do
    stub = fn _req -> {:error, %Req.TransportError{reason: :nxdomain}} end

    state1 = Orchestrator.poll_github_firehose_for_test(%Orchestrator.State{}, request_fun: stub)
    assert Orchestrator.github_next_poll_delay_for_test(state1) == 1_000

    state2 = Orchestrator.poll_github_firehose_for_test(state1, request_fun: stub)
    assert Orchestrator.github_next_poll_delay_for_test(state2) == 2_000
  end

  test "firehose honors Retry-After on rate-limited responses" do
    stub = fn _req ->
      {:ok, %{status: 429, headers: [{"Retry-After", "7"}], body: %{"message" => "rate limited"}}}
    end

    state = Orchestrator.poll_github_firehose_for_test(%Orchestrator.State{}, request_fun: stub)

    assert {:rate_limited, 1} = state.github_connectivity[:firehose]
    assert Orchestrator.github_next_poll_delay_for_test(state) == 7_000
  end

  test "firehose honors X-Poll-Interval on successful responses" do
    stub = fn _req ->
      {:ok, %{status: 200, headers: [{"ETag", ~s("e")}, {"X-Poll-Interval", "13"}], body: []}}
    end

    state = Orchestrator.poll_github_firehose_for_test(%Orchestrator.State{}, request_fun: stub)

    assert state.github_connectivity[:firehose] == nil
    assert Orchestrator.github_next_poll_delay_for_test(state) == 13_000
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
      Orchestrator.poll_github_comments_for_test(state,
        repo: "owner/repo",
        request_fun: request_fun,
        review_issue_fetcher: fn ["human-review", "merging"] -> {:ok, []} end
      )

    assert {:rate_limited, 1} = next.github_connectivity[:comments]
    assert Orchestrator.github_next_poll_delay_for_test(next) == 9_000
  end

  test "a recovering poll clears the connectivity streak" do
    fail = fn _req -> {:error, %Req.TransportError{reason: :nxdomain}} end

    ok = fn req ->
      page = request_page(req)
      body = if page == "1", do: [], else: []
      {:ok, %{status: 200, headers: [{"ETag", ~s("e")}], body: body}}
    end

    state = Orchestrator.poll_github_firehose_for_test(%Orchestrator.State{}, request_fun: fail)
    assert {:dns, 1} = state.github_connectivity[:firehose]
    assert Orchestrator.github_next_poll_delay_for_test(state) == 1_000

    recovered = Orchestrator.poll_github_firehose_for_test(state, request_fun: ok)
    assert recovered.github_connectivity[:firehose] == nil
    assert Orchestrator.github_next_poll_delay_for_test(recovered) == 60_000
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
