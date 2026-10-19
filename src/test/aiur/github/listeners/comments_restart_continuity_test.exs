defmodule Aiur.GitHub.Listeners.CommentsRestartContinuityTest do
  use Aiur.TestSupport

  alias Aiur.Events.Exchange
  alias Aiur.GitHub.Listeners
  alias Aiur.GitHub.Listeners.Comments
  alias Aiur.GitHub.Listeners.Comments.Input

  # A restarted listener begins at %Cursor{}, so its first poll reads back to the boot
  # cutoff: a comment posted while it was down is still in range, and the one it already
  # published comes back and must be dropped by the publisher's per-comment dedup key.
  test "a listener restart neither repeats nor loses a comment wake" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    # Unique per run: the publisher's dedup table outlives a single test.
    ticket = Integer.to_string(900_000 + System.unique_integer([:positive]))
    :ok = Exchange.subscribe("ticket.#{ticket}.issue.commented")
    on_exit(fn -> Listeners.reset() end)
    Listeners.reset()

    {:ok, comments} = Agent.start_link(fn -> [comment(ticket, 1, "comment A", "2026-06-24T12:00:00Z")] end)
    poll(ticket, comments)
    receive_barrier({:event, %{topic: "ticket." <> _, message: "comment A"}})

    previous = Process.whereis(Comments)
    ref = Process.monitor(previous)
    Process.exit(previous, :kill)
    receive_barrier({:DOWN, ^ref, :process, ^previous, :killed})
    Agent.update(comments, &(&1 ++ [comment(ticket, 2, "comment B", "2026-06-24T12:30:00Z")]))
    # The supervisor finishes the restart before answering this call.
    Supervisor.which_children(Listeners)
    assert Process.whereis(Comments) != previous

    poll(ticket, comments)
    # The fresh cursor really read A back, so only dedup keeps it from waking twice.
    assert_received {:served, ["comment A", "comment B"]}
    receive_barrier({:event, %{topic: "ticket." <> _, message: "comment B"}})
    refute_received {:event, %{message: "comment A"}}
    refute_received {:event, %{message: "comment B"}}
  after
    for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
  end

  # Publishing happens in the poll worker before the listener reports the outcome.
  defp poll(ticket, comments) do
    test = self()
    input = %Input{running_targets: [ticket], running_titles: %{}, ownership_key: self(), next_github_delay_ms: nil}

    Listeners.start_comment_poll(input,
      tracker_kind: "github",
      repo: "owner/repo",
      token: "test-gh-token",
      recipient: self(),
      boot_time: DateTime.to_unix(~U[2026-06-24 11:00:00Z]),
      review_issue_fetcher: fn _ -> {:ok, []} end,
      request_fun: &github(&1, ticket, comments, test)
    )

    receive_barrier({:github_listener_outcome, :comments, _outcome})
  end

  defp github(%{url: url}, ticket, comments, test) do
    if String.contains?(url, "/issues/#{ticket}/comments?") do
      since = URI.decode_query(URI.parse(url).query)["since"]
      served = Enum.filter(Agent.get(comments, & &1), &(&1["updated_at"] >= since))
      send(test, {:served, Enum.map(served, & &1["body"])})
      {:ok, %{status: 200, body: served}}
    else
      {:ok, %{status: 200, body: []}}
    end
  end

  # Comment ids are unique per run too: the durable resource store is keyed by them.
  defp comment(ticket, n, body, at),
    do: %{"id" => String.to_integer(ticket) * 10 + n, "body" => body, "created_at" => at, "updated_at" => at, "user" => %{"login" => "its-everdred"}}
end
