defmodule Aiur.LandingWatch.AttributionTest do
  use Aiur.TestSupport

  alias Aiur.LandingWatch.Attribution

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "detects AI co-author trailers and generated-with footers" do
    refute Attribution.clean?("Fix the edge case\n\nCo-Authored-By: Claude Opus <noreply@anthropic.com>")
    refute Attribution.clean?("Improve docs\n\nGenerated with [Codex]")
    assert Attribution.clean?("Fix the edge case\n\nReviewed-by: a human")
  end

  test "paginates commits and stops at the first attributed commit" do
    parent = self()
    next = "https://api.github.com/repos/owner/repo/pulls/17/commits?per_page=100&page=2"

    request = fn %{url: url} ->
      send(parent, {:requested, url})

      if url == next do
        {:ok, %{status: 200, body: [%{"commit" => %{"message" => "Fix test\n\nCo-authored-by: Codex"}}]}}
      else
        {:ok, %{status: 200, body: [%{"commit" => %{"message" => "First commit"}}], headers: [{"link", "<#{next}>; rel=\"next\""}]}}
      end
    end

    assert {:ok, {:ai_attribution, detail}} = Attribution.pull_request_clean?(17, token: "test-gh-token", request_fun: request)
    assert detail =~ "Co-authored-by: Codex"
    assert_received {:requested, "https://api.github.com/repos/owner/repo/pulls/17/commits?per_page=100"}
    assert_received {:requested, ^next}
  end

  test "pagination failures fail closed before landing" do
    assert {:error, _reason} = Attribution.pull_request_clean?(17, token: "test-gh-token", request_fun: fn _ -> {:error, :timeout} end)
  end
end
