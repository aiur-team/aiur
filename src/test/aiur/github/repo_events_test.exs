defmodule Aiur.GitHub.RepoEventsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.RepoEvents

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

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    :ok
  end

  describe "fetch_repo_events/1" do
    test "returns events list on 200 with etag and poll interval" do
      events = [%{"type" => "PushEvent"}]

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/repos/owner/repo/events"
        {:ok, %{status: 200, body: events, headers: [{"etag", ~s("abc123")}, {"x-poll-interval", "30"}]}}
      end

      assert {:ok, {:events, ^events, etag, poll}} =
               RepoEvents.fetch_repo_events(request_fun: request_fun)

      assert etag =~ "abc123"
      assert poll == 30
    end

    test "returns :not_modified on 304 with prior etag" do
      request_fun = fn %{method: :get} ->
        {:ok, %{status: 304, headers: [{"x-poll-interval", "60"}]}}
      end

      assert {:ok, {:not_modified, etag, poll}} =
               RepoEvents.fetch_repo_events(
                 request_fun: request_fun,
                 etag: ~s("prior-etag")
               )

      assert etag == ~s("prior-etag")
      assert poll == 60
    end

    test "returns error on non-200/304 status" do
      request_fun = fn _ -> {:ok, %{status: 500, body: %{"message" => "Error"}}} end
      assert {:error, _} = RepoEvents.fetch_repo_events(request_fun: request_fun)
    end
  end
end
