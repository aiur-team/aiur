defmodule Aiur.LandingWatch.ClassifierTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.Classifier

  test "approval must belong to current head" do
    approved = %{"reviewDecision" => "APPROVED", "headRefOid" => "head", "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head"}}]}}
    stale = put_in(approved, ["reviews", "nodes", Access.at(0), "commit", "oid"], "old")

    assert Classifier.approved_at_head?(approved)
    refute Classifier.approved_at_head?(stale)
    refute Classifier.approved_at_head?(Map.delete(approved, "reviews"))
  end

  test "classifies zero-work and runner failures as infrastructure" do
    assert Classifier.infrastructure_run?(%{
             "conclusion" => "failure",
             "jobs" => [%{"conclusion" => "failure", "steps" => [], "started_at" => "2026-10-14T00:00:00Z", "completed_at" => "2026-10-14T00:00:00Z"}]
           })

    assert Classifier.infrastructure_run?(%{"conclusion" => "failure", "jobs" => [%{"conclusion" => "runner_error", "steps" => [%{"conclusion" => "failure"}]}]})

    refute Classifier.infrastructure_run?(%{
             "conclusion" => "failure",
             "jobs" => [
               %{"conclusion" => "failure", "steps" => [%{"conclusion" => "success"}, %{"conclusion" => "failure"}], "started_at" => "2026-10-14T00:00:00Z", "completed_at" => "2026-10-14T00:00:05Z"}
             ]
           })
  end

  test "a directly cancelled run is held for operator action" do
    refute Classifier.infrastructure_run?(%{"conclusion" => "cancelled", "jobs" => []})
    refute Classifier.infrastructure_run?(%{"conclusion" => "failure", "jobs" => []})
  end

  test "ci gate failure caused by cancelled upstream jobs is infrastructure" do
    run = %{
      "name" => "ci gate",
      "conclusion" => "failure",
      "jobs" => [
        %{
          "name" => "ci gate",
          "conclusion" => "failure",
          "steps" => [%{"name" => "Setup", "conclusion" => "success"}, %{"name" => "Require the event's selected jobs", "conclusion" => "failure"}],
          "started_at" => "2026-10-14T19:34:47Z",
          "completed_at" => "2026-10-14T19:34:54Z"
        }
      ],
      "workflow_jobs" => [
        %{"name" => "test", "conclusion" => "cancelled", "steps" => [], "started_at" => "2026-10-14T19:04:38Z", "completed_at" => "2026-10-14T19:04:38Z"},
        %{
          "name" => "ci gate",
          "conclusion" => "failure",
          "steps" => [%{"name" => "Setup", "conclusion" => "success"}, %{"name" => "Require the event's selected jobs", "conclusion" => "failure"}],
          "started_at" => "2026-10-14T19:34:47Z",
          "completed_at" => "2026-10-14T19:34:54Z"
        }
      ]
    }

    assert Classifier.infrastructure_run?(run)
    refute Classifier.infrastructure_run?(put_in(run, ["workflow_jobs", Access.at(0), "conclusion"], "failure"))
  end
end
