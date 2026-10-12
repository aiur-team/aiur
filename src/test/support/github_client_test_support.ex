defmodule Aiur.GitHub.ClientTestSupport do
  @moduledoc false
  # Shared setup and fixtures for the Aiur.GitHub.Client test files.

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.Workflow

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  def setup_client do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    DispatchAuthorization.clear_cache()
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      Aiur.TestSupport.restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    Aiur.TestSupport.write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    :ok
  end

  def codeowners_repo!(content) do
    repo_root = Aiur.TestSupport.tmp_root!("aiur-github-client-test")

    path = Path.join(repo_root, ".github/CODEOWNERS")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    repo_root
  end

  def review_thread_comment(id, login, body) do
    %{
      "id" => "PRRC_#{id}",
      "databaseId" => id,
      "body" => body,
      "createdAt" => "2026-06-25T04:13:21Z",
      "updatedAt" => "2026-06-25T04:13:21Z",
      "url" => "https://github.test/discussion_r#{id}",
      "author" => %{"login" => login}
    }
  end

  def review_thread_node_response(thread_id, comments, attrs \\ %{}) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "node" =>
             Map.merge(
               %{
                 "id" => thread_id,
                 "isResolved" => false,
                 "path" => "src/lib/aiur/github/client.ex",
                 "line" => 12,
                 "comments" => %{"nodes" => comments}
               },
               attrs
             )
         }
       }
     }}
  end

  def review_threads_page_response(nodes) do
    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{
               "reviewThreads" => %{
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                 "nodes" => nodes
               }
             }
           }
         }
       }
     }}
  end
end
