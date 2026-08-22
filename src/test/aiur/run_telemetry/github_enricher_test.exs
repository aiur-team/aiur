defmodule Aiur.RunTelemetry.GitHubEnricherTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.CodeOwners
  alias Aiur.RunTelemetry.GitHubEnricher

  test "fallback trusts both split Aiur identities without trusting outsiders" do
    write_split_identity_config!()
    unregister_code_owners!()

    result = GitHubEnricher.enrich("owner/repo", ["930"], token: "token", request_fun: &identity_request/1)

    assert Enum.map(result.events, & &1.author) == ["aiur-daemon[bot]", "its-applekid"]
    assert Enum.all?(result.events, & &1.author_trusted?)
    refute Enum.any?(result.events, &(&1.author == "outsider"))
  end

  test "fallback keeps single-identity behavior deduplicated" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_bot_account: "aiur-bot"
    )

    unregister_code_owners!()

    result = GitHubEnricher.enrich("owner/repo", ["930"], token: "token", request_fun: &single_identity_request/1)

    assert [%{author: "aiur-bot", author_trusted?: true}] = result.events
    refute Enum.any?(result.events, &(&1.author == "outsider"))
  end

  test "adds ticket-matched PR boundaries and trusted actionable comments without bodies" do
    request_fun = fn %{url: url} ->
      body =
        cond do
          String.contains?(url, "/pulls?state=all") ->
            [
              %{
                "number" => 77,
                "created_at" => "2026-07-11T12:00:00Z",
                "merged_at" => "2026-07-11T14:00:00Z",
                "head" => %{"ref" => "aiur/930-daemon-side-lifecycle-resource"},
                "user" => nil
              },
              %{
                "number" => 78,
                "created_at" => "2026-07-11T12:30:00Z",
                "head" => %{"ref" => "feature/not-aiur"},
                "user" => %{"login" => "owner"}
              }
            ]

          String.contains?(url, "/issues/930/comments") ->
            [
              comment(100, "owner", "please revise this"),
              comment(101, "stranger", "ignore me"),
              :malformed_comment
            ]

          String.contains?(url, "/issues/77/comments") ->
            [comment(102, "owner", "[codex] review passed")]

          String.contains?(url, "/pulls/77/comments") ->
            [comment(103, "owner", "this line needs rework")]

          String.contains?(url, "/pulls/77/reviews") ->
            [
              review(104, "owner", "please address the review", "CHANGES_REQUESTED"),
              review(105, "owner", nil, "APPROVED"),
              Map.drop(review(106, "owner", "missing timestamp", "CHANGES_REQUESTED"), ["submitted_at"])
            ]

          true ->
            []
        end

      {:ok, %{status: 200, body: body, headers: %{}}}
    end

    result =
      GitHubEnricher.enrich("owner/repo", ["930"],
        request_fun: request_fun,
        trusted_author_fun: &(&1 == "owner")
      )

    assert result.warnings == []
    assert Enum.count(result.events, &(&1.topic == "ticket.930.pr.opened")) == 1
    assert Enum.count(result.events, &(&1.topic == "ticket.930.pr.merged")) == 1

    comments = Enum.filter(result.events, &String.ends_with?(&1.topic, ["issue.commented", "pr.review_comment"]))
    assert MapSet.new(comments, & &1.comment["id"]) == MapSet.new([100, 103, 104])
    assert Enum.all?(comments, &(&1.author_trusted? == true))
    assert Enum.all?(comments, &(not Map.has_key?(&1.comment, "body")))
    assert Enum.find(comments, &(&1.comment["id"] == 104)).comment["updated_at"] == "2026-07-11T13:30:00Z"
    refute inspect(result) =~ "please revise"
    refute inspect(result) =~ "review passed"
  end

  test "invalid repositories and request failures become sanitized warnings" do
    assert %{events: [], warnings: [%{type: :github_enrichment_invalid_repo}]} =
             GitHubEnricher.enrich("not-a-repo", ["930"])

    result =
      GitHubEnricher.enrich("owner/repo", ["930"],
        token: "secret-token",
        request_fun: fn _request -> {:error, {:transport_failed, "secret-token"}} end
      )

    assert result.events == []
    assert [%{type: :github_enrichment_failed, endpoint: :pull_requests, reason: "transport_failed"}] = result.warnings
    refute inspect(result) =~ "secret-token"
  end

  test "pagination and malformed response failures remain sanitized" do
    assert %{events: [], warnings: [%{type: :github_enrichment_invalid_repo}]} =
             GitHubEnricher.enrich("owner/repo", :invalid_tickets)

    pagination_limit =
      GitHubEnricher.enrich("owner/repo", ["930"],
        max_pages: 0,
        request_fun: fn _request -> flunk("pagination limit should fail before a request") end
      )

    assert [%{reason: "pagination_limit"}] = pagination_limit.warnings

    cycle =
      GitHubEnricher.enrich("owner/repo", ["930"],
        request_fun: fn %{url: url} ->
          {:ok,
           %{
             status: 200,
             body: [],
             headers: %{"link" => ~s(<#{url}>; rel="next")}
           }}
        end
      )

    assert [%{reason: "pagination_cycle"}] = cycle.warnings

    status_failure =
      GitHubEnricher.enrich("owner/repo", ["930"], request_fun: fn _request -> {:ok, %{status: 503}} end)

    assert [%{reason: "status_503"}] = status_failure.warnings

    invalid_response =
      GitHubEnricher.enrich("owner/repo", ["930"], request_fun: fn _request -> {:ok, %{body: []}} end)

    assert [%{reason: "invalid_response"}] = invalid_response.warnings

    exception =
      GitHubEnricher.enrich("owner/repo", ["930"], request_fun: fn _request -> raise "request exploded" end)

    assert [%{reason: "request_exception"}] = exception.warnings
  end

  defp comment(id, login, body) do
    %{
      "id" => id,
      "created_at" => "2026-07-11T13:00:00Z",
      "updated_at" => "2026-07-11T13:00:01Z",
      "body" => body,
      "user" => %{"login" => login}
    }
  end

  defp review(id, login, body, state) do
    %{
      "id" => id,
      "submitted_at" => "2026-07-11T13:30:00Z",
      "body" => body,
      "state" => state,
      "user" => %{"login" => login}
    }
  end

  defp write_split_identity_config! do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_bot_account: "its-applekid",
      tracker_github_app_account: "aiur-daemon[bot]"
    )
  end

  defp unregister_code_owners! do
    case Process.whereis(CodeOwners) do
      nil ->
        :ok

      pid ->
        Process.unregister(CodeOwners)

        on_exit(fn ->
          if Process.alive?(pid), do: Process.register(pid, CodeOwners)
        end)
    end

    assert Process.whereis(CodeOwners) == nil
  end

  defp identity_request(%{url: url}) do
    body =
      if String.contains?(url, "/issues/930/comments") do
        [
          comment(201, "aiur-daemon[bot]", "daemon comment"),
          comment(202, "its-applekid", "agent comment"),
          comment(203, "outsider", "outsider comment")
        ]
      else
        []
      end

    {:ok, %{status: 200, body: body, headers: %{}}}
  end

  defp single_identity_request(%{url: url}) do
    body =
      if String.contains?(url, "/issues/930/comments") do
        [comment(204, "aiur-bot", "bot comment"), comment(205, "outsider", "outsider comment")]
      else
        []
      end

    {:ok, %{status: 200, body: body, headers: %{}}}
  end
end
