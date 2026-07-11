defmodule Aiur.Orchestrator.HumanReviewTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.HumanReview

  test "recognizes the human review state" do
    assert HumanReview.human_review_state?("human-review")
    refute HumanReview.human_review_state?("todo")
  end
end
