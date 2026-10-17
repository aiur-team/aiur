defmodule Aiur.LandingWatch.MergeGroupFailureEvidenceTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroupFailureEvidence

  test "a main run list longer than the page cap keeps the read pages instead of failing" do
    parent = self()

    request = fn %{method: :get, url: url} ->
      id = System.unique_integer([:positive])
      send(parent, :main_page)

      {:ok,
       %{
         status: 200,
         body: %{"workflow_runs" => [%{"id" => id, "conclusion" => "failure"}]},
         headers: [{"link", "<#{url}&page=n>; rel=\"next\""}]
       }}
    end

    paths =
      MergeGroupFailureEvidence.recent_main_paths("main",
        token: "test-gh-token",
        request_fun: request,
        jobs_fun: fn id, _ -> {:ok, [%{"id" => id, "conclusion" => "failure"}]} end,
        job_log_fun: fn %{"id" => id}, _ -> {:ok, "test/run_#{id}_test.exs:1"} end
      )

    assert length(paths) == 5
    for _ <- 1..5, do: assert_received(:main_page)
    refute_received :main_page
  end
end
