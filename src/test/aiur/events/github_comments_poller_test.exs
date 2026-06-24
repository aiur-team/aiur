defmodule Aiur.Events.GithubCommentsPollerTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, GithubCommentsPoller, Publisher}
  alias Aiur.GitHub.CodeOwners
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    Publisher.set_tracked_fn(fn _ -> true end)

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      Publisher.set_tracked_fn(fn _ -> true end)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end)

    :ok
  end

  test "returns default cursor without calling GitHub when there are no targets" do
    assert {:ok, %{count: 0, since: "2026-06-24T11:59:00Z"}} =
             GithubCommentsPoller.poll(["", "  "], boot_time: 1_782_302_400)
  end

  test "normalizes and deduplicates watched targets before polling" do
    parent = self()

    request_fun = fn %{url: url} ->
      send(parent, {:requested, url})

      cond do
        String.contains?(url, "/issues/42/comments?") -> {:ok, %{status: 200, body: []}}
        String.contains?(url, "/pulls?") -> {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 0, since: "2026-06-24T11:00:00Z"}} =
             GithubCommentsPoller.poll(["42", " 42 ", ""],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:requested, issue_comments_url}
    assert_receive {:requested, pulls_url}
    refute_receive {:requested, _url}, 100

    assert String.contains?(issue_comments_url, "/issues/42/comments?")
    assert String.contains?(pulls_url, "/pulls?")
  end

  test "polls issue comments directly and publishes issue.commented" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 1001,
                 "body" => "please rework this",
                 "updated_at" => "2026-06-24T12:00:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1, since: "2026-06-24T11:59:59Z"}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: "ticket.42.issue.commented",
                      author_trusted?: true,
                      source: :github,
                      comment: %{"body" => "please rework this"}
                    }},
                   500

    stop_codeowners(codeowners)
  end

  test "polls open PR review comments and publishes pr.review_comment under ticket id" do
    :ok = Exchange.subscribe("ticket.42.pr.review_comment")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: [%{"number" => 77}]}}

        String.contains?(url, "/pulls/77/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 2002,
                 "body" => "line note needs rework",
                 "updated_at" => "2026-06-24T12:01:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}
      end
    end

    assert {:ok, %{count: 1, since: "2026-06-24T12:00:59Z"}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: "ticket.42.pr.review_comment",
                      author_trusted?: true,
                      source: :github,
                      comment: %{"body" => "line note needs rework"}
                    }},
                   500

    stop_codeowners(codeowners)
  end

  test "dedupes comments already published by another source" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 3003,
                 "body" => "same comment",
                 "updated_at" => "2026-06-24T12:02:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500

    assert {:ok, %{count: 0}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    refute_receive {:event, _}, 100
    stop_codeowners(codeowners)
  end

  test "keeps cursor unchanged when published comments have no valid timestamp" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 5005,
                 "body" => "timestamp should not advance",
                 "updated_at" => "not-a-date",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1, since: "2026-06-24T11:00:00Z"}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500
    stop_codeowners(codeowners)
  end

  test "ignores open PR results without a usable PR number" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") -> {:ok, %{status: 200, body: []}}
        String.contains?(url, "/pulls?") -> {:ok, %{status: 200, body: [%{}]}}
      end
    end

    assert {:ok, %{count: 0, since: "2026-06-24T11:00:00Z"}} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )
  end

  test "returns an error instead of advancing cursor when any watched endpoint fails" do
    :ok = Exchange.subscribe("ticket.42.issue.commented")
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 4004,
                 "body" => "issue comment still publishes",
                 "updated_at" => "2026-06-24T12:03:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:error, :timeout}
      end
    end

    assert {:error, [{"42", {:pr_review_comments, {:github_api_request, :timeout}}}]} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event, %{topic: "ticket.42.issue.commented"}}, 500
    stop_codeowners(codeowners)
  end

  test "returns an error when issue comment polling fails" do
    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, "/issues/42/comments?") -> {:error, :timeout}
        String.contains?(url, "/pulls?") -> {:ok, %{status: 200, body: []}}
      end
    end

    assert {:error, [{"42", {:issue_comments, {:github_api_request, :timeout}}}]} =
             GithubCommentsPoller.poll(["42"],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )
  end

  defp ensure_codeowners!(contents) do
    case Process.whereis(CodeOwners) do
      pid when is_pid(pid) ->
        previous_allowlist = CodeOwners.snapshot(pid)
        :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(["its-everdred"])})

        %{pid: pid, path: nil, owned?: false, previous_allowlist: previous_allowlist}

      nil ->
        path = Path.join(System.tmp_dir!(), "aiur-codeowners-#{System.unique_integer([:positive])}")
        File.write!(path, contents)

        {:ok, pid} = CodeOwners.start_link(path: path, refresh_seconds: 3600)

        %{pid: pid, path: path, owned?: true}
    end
  end

  defp stop_codeowners(%{pid: pid, owned?: false, previous_allowlist: previous_allowlist}) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, &%{&1 | allowlist: MapSet.new(previous_allowlist)})
    end
  end

  defp stop_codeowners(%{pid: pid, path: path, owned?: true}) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    File.rm(path)
  end
end
