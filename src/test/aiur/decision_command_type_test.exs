defmodule Aiur.DecisionCommandTypeTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionCommandType

  test "a re-review request classifies supervisor_preferred and reversible" do
    assert DecisionCommandType.for_kind("rework_review") == %{
             authority: :supervisor_preferred,
             reversibility: :reversible
           }

    assert DecisionCommandType.for_kind(" REWORK_REVIEW ") == %{
             authority: :supervisor_preferred,
             reversibility: :reversible
           }
  end

  test "a sequencing question classifies supervisor_allowed and reversible" do
    assert DecisionCommandType.for_kind("sequencing") == %{
             authority: :supervisor_allowed,
             reversibility: :reversible
           }
  end

  test "a legacy attention stays human_required and irreversible" do
    assert DecisionCommandType.for_kind("legacy_attention") == %{
             authority: :human_required,
             reversibility: :irreversible
           }
  end

  test "an unknown, blank, or missing kind has no explicit classification" do
    assert DecisionCommandType.for_kind("architecture") == nil
    assert DecisionCommandType.for_kind("") == nil
    assert DecisionCommandType.for_kind("   ") == nil
    assert DecisionCommandType.for_kind(nil) == nil
  end

  test "the classifications table is the single source of truth" do
    classifications = DecisionCommandType.classifications()

    for {kind, %{authority: authority, reversibility: reversibility}} <- classifications do
      assert DecisionCommandType.for_kind(kind) == %{authority: authority, reversibility: reversibility}
    end

    # Every classified policy is a closed-vocabulary authority/reversibility the
    # Executor floor understands.
    assert Enum.all?(classifications, fn {_kind, %{authority: authority}} ->
             authority in [:human_required, :supervisor_allowed, :supervisor_preferred]
           end)

    assert Enum.all?(classifications, fn {_kind, %{reversibility: reversibility}} ->
             reversibility in [:reversible, :irreversible, :partially_reversible]
           end)
  end
end
