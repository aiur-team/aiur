defmodule AiurWeb.OperatorControlCenter.UnitsPresentationTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.Models
  alias AiurWeb.OperatorControlCenter.UnitsPresentation

  describe "model_version/1" do
    test "the model the running agent reported wins over the one its route asked for" do
      # The route names a tag; only the running session can say which concrete
      # version answered, so an observation must never be shadowed by the ask.
      row = %{backend: "claude", requested_model: "opus", resolved_model: "claude-opus-5-1"}

      assert UnitsPresentation.model_version(row) == %{label: "OPUS 5.1", id: "claude-opus-5-1"}
    end

    test "falls back to the route's model before the agent has reported one" do
      row = %{backend: "claude", requested_model: "claude-sonnet-5", resolved_model: nil}

      assert UnitsPresentation.model_version(row) == %{label: "SONNET 5", id: "claude-sonnet-5"}
    end

    test "falls back to the backend's own default when the route pins nothing" do
      # A bare `deepseek` route still runs a specific model; the registry knows
      # which one, so the chip names it rather than going blank.
      row = %{backend: "deepseek", requested_model: nil, resolved_model: nil}
      default = CodingAgent.resolve_model("deepseek", nil)

      assert %{label: label, id: ^default} = UnitsPresentation.model_version(row)
      assert label == Models.label(default)
    end

    test "a row no source can name renders no chip rather than an empty one" do
      assert UnitsPresentation.model_version(%{backend: "claude"}) == nil
      assert UnitsPresentation.model_version(%{backend: nil, requested_model: nil, resolved_model: nil}) == nil
      assert UnitsPresentation.model_version(%{}) == nil
      assert UnitsPresentation.model_version(nil) == nil
    end

    test "carries the raw id alongside the label so the chip can title it" do
      row = %{backend: "codex", resolved_model: "gpt-5.5-codex"}

      assert %{label: "GPT-5.5", id: "gpt-5.5-codex"} = UnitsPresentation.model_version(row)
    end
  end
end
