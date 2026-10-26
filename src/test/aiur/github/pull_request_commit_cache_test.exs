defmodule Aiur.GitHub.PullRequestCommitCacheTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{PullRequests, ReadCache}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    ReadCache.reset()

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    on_exit(fn -> restore_env("GITHUB_TOKEN", prev_token) end)
    :ok
  end

  test "merged commit messages are shared by PR head and fetched again for a new head" do
    number = System.unique_integer([:positive])
    parent = self()
    requests = :atomics.new(1, [])

    first_fetch = fn request ->
      :atomics.add(requests, 1, 1)
      send(parent, {:fetched, request.url})
      send(parent, {:waiting, self()})

      receive do
        :release_fetch ->
          {:ok, %{status: 200, body: [%{"commit" => %{"message" => "Refs #5605"}}], headers: []}}
      after
        1_000 -> flunk("the test must release the blocked commit fetch")
      end
    end

    concurrent =
      for _ <- 1..2 do
        Task.async(fn -> PullRequests.fetch_pull_request_commits(number, request_fun: first_fetch, head_sha: "head-one") end)
      end

    assert_receive {:fetched, url}, 1000
    assert url =~ "/pulls/#{number}/commits"
    wait_for_second_fetch_task(concurrent)
    assert Enum.map(concurrent, &Task.await(&1, 1000)) == [{:ok, ["Refs #5605"]}, {:ok, ["Refs #5605"]}]
    assert :atomics.get(requests, 1) == 1

    assert {:ok, ["Refs #5605"]} =
             PullRequests.fetch_pull_request_commits(number, request_fun: fn _ -> flunk("same head must use cached commit messages") end, head_sha: "head-one")

    second_head_fetch = fn request ->
      :atomics.add(requests, 1, 1)
      send(parent, {:fetched, request.url})
      {:ok, %{status: 200, body: [%{"commit" => %{"message" => "Refs #5605"}}], headers: []}}
    end

    assert {:ok, ["Refs #5605"]} =
             PullRequests.fetch_pull_request_commits(number, request_fun: second_head_fetch, head_sha: "head-two")

    assert_receive {:fetched, _url}, 1000
    assert :atomics.get(requests, 1) == 2
  end

  defp wait_for_second_fetch_task(_concurrent) do
    assert_receive {:waiting, pid}, 1_000
    send(pid, :release_fetch)
  end
end
