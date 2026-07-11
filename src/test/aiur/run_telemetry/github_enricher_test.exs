defmodule Aiur.RunTelemetry.GitHubEnricherTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.GitHubEnricher

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
                "user" => %{"login" => "owner"}
              },
              %{
                "number" => 78,
                "created_at" => "2026-07-11T12:30:00Z",
                "head" => %{"ref" => "feature/not-aiur"},
                "user" => %{"login" => "owner"}
              }
            ]

          String.contains?(url, "/issues/930/comments") ->
            [comment(100, "owner", "please revise this"), comment(101, "stranger", "ignore me")]

          String.contains?(url, "/issues/77/comments") ->
            [comment(102, "owner", "[codex] review passed")]

          String.contains?(url, "/pulls/77/comments") ->
            [comment(103, "owner", "this line needs rework")]

          String.contains?(url, "/pulls/77/reviews") ->
            [comment(104, "owner", "please address the review")]

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

  defp comment(id, login, body) do
    %{
      "id" => id,
      "created_at" => "2026-07-11T13:00:00Z",
      "updated_at" => "2026-07-11T13:00:01Z",
      "body" => body,
      "user" => %{"login" => login}
    }
  end
end
