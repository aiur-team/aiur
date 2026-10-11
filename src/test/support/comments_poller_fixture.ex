defmodule Aiur.TestSupport.CommentsPollerFixture do
  @moduledoc false
  import Aiur.TestSupport
  import Aiur.TestSupport.EventTicket
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.GitHub.{CodeOwners, ResourceStore}
  alias Aiur.Workflow

  # Shared `setup` for every comments-poller test file.
  def comments_poller_env(_context) do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    Publisher.set_tracked_fn(fn _ -> true end)

    ExUnit.Callbacks.on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      Publisher.set_tracked_fn(fn _ -> true end)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end

      # This suite publishes reviews and comments through the shared
      # `Publisher`, which marks them in `ResourceStore` and records their
      # dedup keys in the volatile `Publisher.Dedup` window. Neither is cleared
      # per test anywhere else, so a sibling suite that publishes the same
      # review ids (e.g. `WebhookPollReconciliationTest`) would be silently
      # suppressed by the leaked marks/keys when this suite runs first. Clean
      # both up so the shared state is self-contained per module.
      ResourceStore.reset()

      case :ets.whereis(Aiur.Events.Publisher.Dedup) do
        :undefined -> :ok
        table -> :ets.delete_all_objects(table)
      end
    end)

    :ok
  end

  def ensure_codeowners!(contents) do
    case Process.whereis(CodeOwners) do
      pid when is_pid(pid) ->
        previous_allowlist = CodeOwners.snapshot(pid)
        :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(["its-everdred"])})

        %{pid: pid, path: nil, owned?: false, previous_allowlist: previous_allowlist}

      nil ->
        path =
          Aiur.TestSupport.tmp_root!("aiur-codeowners")

        File.write!(path, contents)

        {:ok, pid} = CodeOwners.start_link(path: path, refresh_seconds: 3600)

        %{pid: pid, path: path, owned?: true}
    end
  end

  def ensure_configured_codeowners!(contents) do
    path = Aiur.TestSupport.tmp_root!("aiur-codeowners")
    File.write!(path, contents)

    case Process.whereis(CodeOwners) do
      pid when is_pid(pid) ->
        previous_state = :sys.get_state(pid)

        :sys.replace_state(pid, fn state ->
          %{state | allowlist: MapSet.new(["__codeowners_bootstrap__"]), codeowners_path: path}
        end)

        :ok = CodeOwners.refresh(pid)

        %{pid: pid, path: path, owned?: false, previous_state: previous_state}

      nil ->
        {:ok, pid} = CodeOwners.start_link(path: path, refresh_seconds: 3600)
        %{pid: pid, path: path, owned?: true}
    end
  end

  def configure_github(opts) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_bot_account: Keyword.get(opts, :bot_account),
      tracker_trusted_accounts: Keyword.get(opts, :trusted_accounts, [])
    )
  end

  def stop_codeowners(%{pid: pid, owned?: false, previous_allowlist: previous_allowlist}) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(previous_allowlist)})
    end
  end

  def stop_codeowners(%{pid: pid, path: path, owned?: false, previous_state: previous_state}) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, fn _state -> previous_state end)
    end

    File.rm(path)
  end

  def stop_codeowners(%{pid: pid, path: path, owned?: true}) do
    Aiur.TestSupport.safe_stop(pid)
    File.rm(path)
  end

  def empty_review_threads_response, do: review_threads_response([])

  def review_threads_response(nodes) do
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

  def review_thread_comment(id, login, body) do
    %{
      "databaseId" => id,
      "body" => body,
      "createdAt" => "2026-06-24T10:00:00Z",
      "updatedAt" => "2026-06-24T10:00:00Z",
      "url" => "https://github.test/discussion_r#{id}",
      "author" => %{"login" => login}
    }
  end

  def pr_review(id, login, state, body, submitted_at \\ "2026-06-24T12:00:00Z") do
    %{
      "id" => id,
      "state" => state,
      "body" => body,
      "submitted_at" => submitted_at,
      "user" => %{"login" => login}
    }
  end

  def request_fun_with_reviews(reviews) do
    ticket = ticket_id()
    fixture_value0 = "/issues/#{ticket}/comments?"
    fixture_value1 = "aiur/#{ticket}"

    fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value0) ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok,
           %{
             status: 200,
             body: [%{"number" => 77, "head" => %{"ref" => fixture_value1, "repo" => %{"full_name" => "owner/repo"}}}]
           }}

        String.contains?(url, "/issues/77/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/graphql") ->
          empty_review_threads_response()

        String.contains?(url, "/pulls/77/reviews") ->
          {:ok, %{status: 200, body: reviews}}
      end
    end
  end
end
