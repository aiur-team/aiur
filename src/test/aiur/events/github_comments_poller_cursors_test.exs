defmodule Aiur.Events.GithubCommentsPollerCursorsTest do
  use Aiur.TestSupport
  use Aiur.TestSupport.EventTicket
  import Aiur.TestSupport.CommentsPollerFixture

  alias Aiur.Events.Exchange
  alias Aiur.Events.GithubCommentsPoller

  setup :comments_poller_env

  test "trusts configured accounts when CODEOWNERS does not include the commenter" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    :ok = Exchange.subscribe(fixture_topic0)

    configure_github(trusted_accounts: ["its-everdred"])
    codeowners = ensure_configured_codeowners!("* @someone-else\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 2602,
                 "body" => "trusted by config",
                 "updated_at" => "2026-06-24T12:03:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok, %{count: 1, since: %{^ticket => "2026-06-24T12:02:59Z"}, errors: []}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event,
                    %{
                      topic: ^fixture_topic0,
                      author_trusted?: true,
                      source: :github,
                      message: "trusted by config",
                      comment: %{"body" => "trusted by config"}
                    }},
                   500

    stop_codeowners(codeowners)
  end

  test "dedupes comments already published by another source" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
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
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event, %{topic: ^fixture_topic0}}, 500

    assert {:ok, %{count: 0}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    refute_receive {:event, _}, 100
    stop_codeowners(codeowners)
  end

  test "keeps cursor unchanged when published comments have no valid timestamp" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
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

    assert {:ok, %{count: 1, since: %{^ticket => "2026-06-24T11:00:00Z"}, errors: []}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event, %{topic: ^fixture_topic0}}, 500
    stop_codeowners(codeowners)
  end

  test "ignores open PR results without a usable PR number" do
    ticket = ticket_id()
    fixture_value0 = "/issues/#{ticket}/comments?"

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value0) -> {:ok, %{status: 200, body: []}}
        String.contains?(url, "/pulls?") -> {:ok, %{status: 200, body: [%{}]}}
      end
    end

    assert {:ok, %{count: 0, since: %{^ticket => "2026-06-24T11:00:00Z"}, errors: []}} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )
  end

  test "advances successful target cursor when another target fails" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 4204,
                 "body" => "target A still moves",
                 "updated_at" => "2026-06-24T12:04:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        # Both targets read the same open-pull-request listing URL now that the
        # per-target `head=<owner>:aiur/<n>` probe is gone — it could only find
        # branches the listing's own filter already matches, so it was a billed
        # request per target per cycle that answered nothing new. The failing
        # target is therefore made to fail on a request that is still its own:
        # its issue-comment read.
        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/issues/43/comments?") ->
          {:error, :timeout}
      end
    end

    assert {:ok,
            %{
              count: 1,
              since: %{
                ^ticket => "2026-06-24T12:03:59Z",
                "43" => "2026-06-24T11:00:00Z"
              },
              errors: [{"43", {:issue_comments, {:github, :timeout, %{reason: :timeout}}}}]
            }} =
             GithubCommentsPoller.poll([ticket, "43"],
               since: %{ticket => "2026-06-24T11:00:00Z", "43" => "2026-06-24T11:00:00Z"},
               repo: "owner/repo",
               request_fun: request_fun,
               max_concurrency: 2
             )

    assert_receive {:event, %{topic: ^fixture_topic0}}, 500
    stop_codeowners(codeowners)
  end

  test "keeps successful target isolated when another target task crashes" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => 4205,
                 "body" => "target A still publishes",
                 "updated_at" => "2026-06-24T12:05:00Z",
                 "user" => %{"login" => "its-everdred"}
               }
             ]
           }}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/issues/43/comments?") ->
          raise "target 43 crash"
      end
    end

    assert {:ok,
            %{
              count: 1,
              since: %{
                ^ticket => "2026-06-24T12:04:59Z",
                "43" => "2026-06-24T11:00:00Z"
              },
              errors: errors
            }} =
             GithubCommentsPoller.poll([ticket, "43"],
               since: %{ticket => "2026-06-24T11:00:00Z", "43" => "2026-06-24T11:00:00Z"},
               repo: "owner/repo",
               request_fun: request_fun,
               max_concurrency: 2
             )

    assert [{"43", {:target, {:exit, {%RuntimeError{message: "target 43 crash"}, [_ | _]}}}}] =
             errors

    assert_receive {:event, %{topic: ^fixture_topic0}}, 500
    stop_codeowners(codeowners)
  end

  test "reports timed out target task as target-local error" do
    ticket = ticket_id()
    fixture_value0 = "/issues/#{ticket}/comments?"

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value0) ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/pulls?") ->
          {:ok, %{status: 200, body: []}}

        String.contains?(url, "/issues/43/comments?") ->
          Process.sleep(:infinity)
      end
    end

    assert {:ok,
            %{
              count: 0,
              since: %{
                ^ticket => "2026-06-24T11:00:00Z",
                "43" => "2026-06-24T11:00:00Z"
              },
              errors: [{"43", {:target, {:exit, :timeout}}}]
            }} =
             GithubCommentsPoller.poll([ticket, "43"],
               since: %{ticket => "2026-06-24T11:00:00Z", "43" => "2026-06-24T11:00:00Z"},
               repo: "owner/repo",
               request_fun: request_fun,
               max_concurrency: 2,
               timeout: 1_000
             )
  end

  test "reports an error and leaves target cursor unchanged when any watched endpoint fails" do
    ticket = ticket_id()
    fixture_topic0 = "ticket.#{ticket}.issue.commented"
    fixture_value1 = "/issues/#{ticket}/comments?"
    :ok = Exchange.subscribe(fixture_topic0)
    codeowners = ensure_codeowners!("* @its-everdred\n")

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value1) ->
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

    assert {:ok,
            %{
              count: 1,
              since: %{^ticket => "2026-06-24T11:00:00Z"},
              errors: [{^ticket, {:pr_lookup, {:github, :timeout, %{reason: :timeout}}}}]
            }} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )

    assert_receive {:event, %{topic: ^fixture_topic0}}, 500
    stop_codeowners(codeowners)
  end

  test "reports an error when issue comment polling fails" do
    ticket = ticket_id()
    fixture_value0 = "/issues/#{ticket}/comments?"

    request_fun = fn %{url: url} ->
      cond do
        String.contains?(url, fixture_value0) -> {:error, :timeout}
        String.contains?(url, "/pulls?") -> {:ok, %{status: 200, body: []}}
      end
    end

    assert {:ok,
            %{
              count: 0,
              since: %{^ticket => "2026-06-24T11:00:00Z"},
              errors: [{^ticket, {:issue_comments, {:github, :timeout, %{reason: :timeout}}}}]
            }} =
             GithubCommentsPoller.poll([ticket],
               since: "2026-06-24T11:00:00Z",
               repo: "owner/repo",
               request_fun: request_fun
             )
  end
end
