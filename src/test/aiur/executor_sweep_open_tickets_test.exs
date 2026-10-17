defmodule Aiur.ExecutorSweep.OpenTicketsTest do
  use Aiur.TestSupport

  alias Aiur.ExecutorSweep.{Checks, SnapshotCache}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.OpenTicketSource

  setup do
    if Process.whereis(ResourceStore) == nil, do: Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    Aiur.TestSupport.ensure_pubsub_running()
    ResourceStore.reset()
    on_exit(fn -> ResourceStore.reset() end)
    :ok
  end

  # #4779: the store keeps label rows for closed issues in both REST and GraphQL
  # spelling; only open tickets may yield state-label findings.
  test "state-label findings cover open tickets only" do
    {:ok, source} =
      OpenTicketSource.start_link(
        name: nil,
        poll_on_start: false,
        repo_fun: fn -> {:ok, {"owner", "repo"}} end,
        token_fun: fn -> {:ok, "token"} end,
        label_prefix: "aiur",
        github_fun: fn -> true end
      )

    deposit(1084, "closed", [])
    deposit(1099, "CLOSED", ["agent:done", "agent:human-review"])
    deposit(7, "open", [])
    deposit(8, "OPEN", ["agent:todo", "agent:rework"])
    deposit(9, "open", ["agent:todo"])

    snapshot_fun = fn -> OpenTicketSource.snapshot(source) end
    assert eventually(fn -> length(snapshot_fun.().tickets) == 3 end)

    snapshot = SnapshotCache.build([], [], SnapshotCache.open_tickets(snapshot_fun))
    flagged = Checks.all(snapshot, ~U[2026-10-16 20:33:00Z]) |> Enum.filter(&(&1.kind == "invalid_state_labels")) |> Enum.map(& &1.ticket)

    assert Enum.sort(flagged) == [7, 8]
    GenServer.stop(source)
  end

  test "an unreachable open-ticket source yields no tickets" do
    assert [] = SnapshotCache.open_tickets(fn -> exit(:noproc) end)
  end

  defp deposit(number, state, labels) do
    labels = Enum.map(labels, &%{"name" => &1})
    issue = %{"number" => number, "title" => "Ticket #{number}", "state" => state, "created_at" => "2026-10-01T00:00:00Z", "updated_at" => "2026-10-16T00:00:00Z", "labels" => labels}
    ResourceStore.put_resource(ResourceStore.key(:issue, "owner", "repo", number), issue, source: :webhook, version: issue["updated_at"])
    ResourceStore.put_resource(ResourceStore.key(:issue_labels, "owner", "repo", number), labels, source: :webhook, version: issue["updated_at"])
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end
end
