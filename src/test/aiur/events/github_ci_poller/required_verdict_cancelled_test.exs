defmodule Aiur.Events.GithubCIPoller.RequiredVerdictCancelledTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.GithubCIPoller.Evaluation

  test "cancelled pull request jobs settle a failed gate as pending after required checks load" do
    jobs = [
      %{"name" => "changes", "status" => "completed", "conclusion" => "success"},
      %{"name" => "soak", "status" => "completed", "conclusion" => "skipped"},
      %{"name" => "test", "status" => "completed", "conclusion" => "cancelled"},
      %{"name" => "ci gate", "status" => "completed", "conclusion" => "failure"}
    ]

    result = %{decision: :failed, failures: [%{name: "ci gate"}]}

    pr = %{
      "head" => %{"sha" => "head"},
      "merge_queue" => %{merge_queue_entry: %{"state" => "UNMERGEABLE"}}
    }

    opts = [required_checks: {:ok, [%{name: "ci gate", app_id: nil}]}]

    assert %{
             decision: :pending,
             pending_reason: :ci_cancelled,
             failures: []
           } = Evaluation.enforce_required_checks(result, jobs, %{"statuses" => []}, pr, opts)
  end

  test "cancelled jobs do not hide unavailable required-check configuration" do
    jobs = [
      %{"name" => "test", "status" => "completed", "conclusion" => "cancelled"},
      %{"name" => "ci gate", "status" => "completed", "conclusion" => "failure"}
    ]

    result = %{decision: :failed, failures: [%{name: "ci gate"}]}

    pr = %{
      "head" => %{"sha" => "head"},
      "merge_queue" => %{merge_queue_entry: %{"state" => "UNMERGEABLE"}}
    }

    assert %{decision: :pending, pending_reason: :required_checks_unavailable} =
             Evaluation.enforce_required_checks(
               result,
               jobs,
               %{"statuses" => []},
               pr,
               required_checks: {:error, :offline}
             )
  end
end
