defmodule Aiur.Executor.TakeoverAlert.SnapshotTest do
  use Aiur.TestSupport

  alias Aiur.Executor.TakeoverAlert.Snapshot

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  defp pr_body do
    %{
      "number" => 1144,
      "state" => "open",
      "created_at" => "2026-01-01T00:00:00Z",
      "mergeable_state" => "clean",
      "head" => %{
        "ref" => "aiur/101",
        "sha" => "abc123",
        "repo" => %{"full_name" => "owner/repo"}
      },
      "base" => %{"ref" => "develop"}
    }
  end

  defp fork_pr_body do
    %{pr_body() | "head" => %{"ref" => "aiur/101", "sha" => "abc123", "repo" => %{"full_name" => "contributor/repo"}}}
  end

  defp repoless_pr_body do
    %{pr_body() | "head" => %{"ref" => "aiur/101", "sha" => "abc123"}}
  end

  defp request_fun_returning(pull_requests) do
    fn %{method: :get, url: url} ->
      cond do
        url =~ "/pulls/1144" ->
          {:ok, %{status: 200, body: pr_body(), headers: []}}

        url =~ "/commits/abc123" ->
          {:ok,
           %{
             status: 200,
             body: %{"commit" => %{"committer" => %{"date" => "2026-01-01T02:00:00Z"}}},
             headers: []
           }}

        # The open-pull-request listing, which no longer carries a
        # `head=<owner>:aiur/<n>` probe. `pr_body/0` already declares
        # `head.ref`, so `TicketBranch.ticket_branch?/2` matches ticket 101.
        url =~ "/pulls?" ->
          {:ok, %{status: 200, body: pull_requests, headers: []}}

        true ->
          {:ok, %{status: 200, body: [], headers: []}}
      end
    end
  end

  test "preserves terminal members and reports authoritative snapshot health" do
    membership_fun = fn ->
      %{
        health: :healthy,
        truncated?: false,
        members: [
          %{identity: %{identifier: "101"}, terminal?: false},
          %{identity: %{identifier: "202"}, terminal?: true}
        ]
      }
    end

    assert %{authoritative?: true, tickets: tickets} =
             Snapshot.fetch(DateTime.utc_now(), membership_fun: membership_fun, running_fun: fn -> ["101"] end)

    assert %{terminal?: false, live_owner?: true} = Enum.find(tickets, &(&1.identifier == "101"))
    assert %{terminal?: true, live_owner?: false} = Enum.find(tickets, &(&1.identifier == "202"))
  end

  test "marks degraded and truncated membership snapshots non-authoritative" do
    for snapshot <- [
          %{health: {:degraded, :test}, truncated?: false, members: []},
          %{health: :healthy, truncated?: true, members: []}
        ] do
      assert %{authoritative?: false} =
               Snapshot.fetch(DateTime.utc_now(), membership_fun: fn -> snapshot end, running_fun: fn -> [] end)
    end
  end

  test "parses open-PR evidence from the matching ticket branch" do
    assert {:ok,
            %{
              number: 1144,
              created_at: %DateTime{},
              pushed_at: %DateTime{},
              mergeable_state: "clean",
              ci_state: nil
            }} = Snapshot.fetch_open_pr(%{identifier: "101"}, request_fun: request_fun_returning([pr_body()]))
  end

  test "refuses a fork pull request that reuses the ticket branch name" do
    assert {:ok, nil} == Snapshot.fetch_open_pr(%{identifier: "101"}, request_fun: request_fun_returning([fork_pr_body()]))
  end

  test "refuses a pull request that names no head repository" do
    assert {:ok, nil} ==
             Snapshot.fetch_open_pr(%{identifier: "101"},
               request_fun: request_fun_returning([repoless_pr_body()])
             )
  end

  test "returns nil when no open PR exists for the ticket" do
    assert {:ok, nil} == Snapshot.fetch_open_pr(%{identifier: "101"}, request_fun: request_fun_returning([]))
  end

  test "returns nil when the tracker is unavailable" do
    request_fun = fn _request -> {:error, :network} end
    assert {:error, _reason} = Snapshot.fetch_open_pr(%{identifier: "101"}, request_fun: request_fun)
  end

  test "enriches CI state only for already-alerted tickets" do
    request_fun = fn %{method: :get, url: url} ->
      cond do
        url =~ "check-runs" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "check_runs" => [
                 %{"status" => "completed", "conclusion" => "failure"},
                 %{"status" => "completed", "conclusion" => "success"}
               ]
             },
             headers: []
           }}

        url =~ "commits/abc123/status" ->
          {:ok, %{status: 200, body: %{}, headers: []}}

        true ->
          request_fun_returning([pr_body()]).(%{method: :get, url: url})
      end
    end

    assert {:ok, %{ci_state: "failing (1 check)"}} =
             Snapshot.fetch_open_pr(%{identifier: "101", enrich_ci?: true}, request_fun: request_fun)
  end

  test "an ordinary ticket does not pay for CI enrichment" do
    request_fun = fn %{method: :get, url: url} ->
      refute url =~ "check-runs"
      request_fun_returning([pr_body()]).(%{method: :get, url: url})
    end

    assert {:ok, %{ci_state: nil}} = Snapshot.fetch_open_pr(%{identifier: "101"}, request_fun: request_fun)
  end
end
