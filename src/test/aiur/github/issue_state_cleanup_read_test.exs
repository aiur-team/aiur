defmodule Aiur.GitHub.IssueStateCleanupReadTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{IssueState, ResourceStore}

  @token_cache_key {Aiur.GitHub.Access.Token, :resolved_token}

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)

      case previous_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  test "cleanup fetches authoritative labels without the stored validator" do
    key = ResourceStore.key_for_repo(:issue, "owner/repo", "42")

    ResourceStore.put_resource(
      key,
      %{"state" => "open", "labels" => [%{"name" => "sym:todo"}]},
      source: :webhook,
      version: "2026-06-24T10:00:00Z",
      etag: ~s("issue-etag")
    )

    gets = :ets.new(:cleanup_read_gets, [:set, :public])
    :ets.insert(gets, {:count, 0})

    request_fun = fn request ->
      if request.method == :get do
        count = :ets.update_counter(gets, :count, 1)
        if count < 3, do: assert(request.etag == ~s("issue-etag")), else: refute(Map.has_key?(request, :etag))

        labels =
          case count do
            count when count < 3 -> ["sym:todo"]
            3 -> ["sym:todo", "sym:rework"]
            _ -> ["sym:rework"]
          end

        body = %{"state" => "open", "labels" => Enum.map(labels, &%{"name" => &1})}

        {:ok, %{status: 200, body: body}}
      else
        {:ok, %{status: 200, body: [%{"name" => "sym:rework"}]}}
      end
    end

    assert :ok = IssueState.update_issue_state("42", "rework", request_fun: request_fun)
    assert :ets.lookup_element(gets, :count, 2) == 4
  end
end
