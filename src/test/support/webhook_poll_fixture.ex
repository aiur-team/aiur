defmodule Aiur.TestSupport.WebhookPollFixture do
  @moduledoc false
  # Keep polling stubs and webhook fixtures together so both paths describe the same events.
  import ExUnit.Assertions
  import Aiur.TestSupport.EventTicket
  alias Aiur.Events.GithubCommentsPoller
  alias Aiur.GitHub.ResourceStore
  @repo "owner/repo"

  def sweep(response, opts \\ []) do
    ticket = ticket_id()
    {:ok, recorder} = Agent.start_link(fn -> [] end)
    etag = Keyword.get(opts, :etag, ~s("v1"))

    request_fun = fn request ->
      Agent.update(recorder, &(&1 ++ [request]))

      case response do
        :not_modified ->
          {:ok, %{status: 304, headers: [{"etag", etag}]}}

        comments when is_list(comments) ->
          {:ok, %{status: 200, body: comments, headers: [{"etag", etag}]}}
      end
    end

    result =
      GithubCommentsPoller.poll([ticket],
        since: "2026-06-24T11:00:00Z",
        repo: @repo,
        request_fun: request_fun,
        comment_batch: %{ticket => %{open_pull_request: nil}}
      )

    calls = Agent.get(recorder, & &1)
    Agent.stop(recorder)

    {calls, result}
  end

  # Runs one review-submission poll cycle against a recording request stub and
  # returns {requests, result}. The `open_pull_request` batch entry points the
  # cycle at PR 77's review list; issue/PR conversation comments and the
  # GraphQL thread read answer from the batch so the only request under test is
  # `/pulls/77/reviews`.
  def review_sweep(response, opts \\ []) do
    ticket = ticket_id()
    {:ok, recorder} = Agent.start_link(fn -> [] end)
    etag = Keyword.get(opts, :etag, ~s("rv1"))

    request_fun = fn request ->
      Agent.update(recorder, &(&1 ++ [request]))

      case response do
        :not_modified ->
          {:ok, %{status: 304, headers: [{"etag", etag}]}}

        reviews when is_list(reviews) ->
          {:ok, %{status: 200, body: reviews, headers: [{"etag", etag}]}}
      end
    end

    result =
      GithubCommentsPoller.poll([ticket],
        since: "2026-06-24T11:00:00Z",
        repo: @repo,
        request_fun: request_fun,
        comment_batch: %{
          ticket => %{
            open_pull_request: %{"number" => 77},
            issue_comments: [],
            pr_issue_comments: [],
            review_thread_comments: []
          }
        }
      )

    calls = Agent.get(recorder, & &1)
    Agent.stop(recorder)

    {calls, result}
  end

  def delivery(id, body) do
    number = ticket_number()

    %{
      "action" => "created",
      "repository" => %{"full_name" => @repo},
      "issue" => %{"number" => number},
      "comment" => comment(id, body),
      "sender" => %{"login" => "its-everdred"}
    }
  end

  def review_thread_delivery(action, updated_at) do
    ticket = ticket_id()
    fixture_value0 = "aiur/#{ticket}-reopen"

    %{
      "action" => action,
      "repository" => %{"full_name" => @repo},
      "thread" => %{
        "id" => 88_001,
        "node_id" => "PRRT_kwDOreopen",
        "comments" => 1
      },
      "updated_at" => updated_at,
      "pull_request" => %{
        "number" => 901,
        "head" => %{
          "ref" => fixture_value0,
          "sha" => "deadbeef",
          "repo" => %{"full_name" => @repo}
        }
      }
    }
  end

  def thread_sweep(thread_comment) do
    ticket = ticket_id()

    GithubCommentsPoller.poll([ticket],
      since: "2026-06-24T11:00:00Z",
      repo: @repo,
      review_submission_targets: MapSet.new([]),
      open_pull_requests_by_target: %{ticket => %{"number" => 901}},
      comment_batch: %{
        ticket => %{issue_comments: [], pr_issue_comments: [], review_thread_comments: [thread_comment]}
      }
    )
  end

  def comment(id, body, updated_at \\ "2026-06-24T12:00:00Z") do
    %{
      "id" => id,
      "body" => body,
      "created_at" => updated_at,
      "updated_at" => updated_at,
      "html_url" => "https://example.test/comments/#{id}",
      "user" => %{"login" => "its-everdred"}
    }
  end

  # A review submission as `GET /pulls/N/reviews` reports it — `state` in upper
  # case, `submitted_at` as the mutation marker the `:pr_review` resource
  # version is keyed on.
  def review(id, login, state, body, submitted_at) do
    %{
      "id" => id,
      "state" => state,
      "body" => body,
      "submitted_at" => submitted_at,
      "user" => %{"login" => login}
    }
  end

  def review_delivery(review) do
    ticket = ticket_id()
    fixture_value0 = "aiur/#{ticket}-some-slug"

    %{
      "action" => "submitted",
      "repository" => %{"full_name" => @repo},
      "review" => review,
      "pull_request" => %{"number" => 77, "head" => %{"ref" => fixture_value0, "sha" => "deadbeef"}},
      "sender" => %{"login" => "its-everdred"}
    }
  end

  # Empties only the volatile replay window, leaving the durable resource marks
  # in place — the state a daemon restart actually produces.
  def clear_replay_window do
    case :ets.whereis(Aiur.Events.Publisher.Dedup) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  def restart_store!(path) do
    pid = Process.whereis(ResourceStore)
    ref = Process.monitor(pid)
    Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> flunk("ResourceStore did not stop")
    end

    Application.put_env(:aiur, :github_resource_store_path, path)
    {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
    :ok
  end

  def await_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> event
    after
      1_000 -> flunk("no event published on #{topic}")
    end
  end

  def refute_event(topic) do
    receive do
      {:event, %{topic: ^topic} = event} -> flunk("unexpected second publish on #{topic}: #{inspect(event)}")
    after
      200 -> :ok
    end
  end
end
