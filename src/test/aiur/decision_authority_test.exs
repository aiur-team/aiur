defmodule Aiur.DecisionAuthorityTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionAuthority

  @safe_policy %{allowed_kinds: ["architecture"], allow_non_reversible: false}

  test "safe defaults deny a supervisor mutation" do
    evaluation = evaluate(:supervisor_allowed, "architecture", :reversible, %{})

    refute evaluation.allowed
    assert evaluation.reasons == [:kind_not_allowed]

    assert evaluation.checks == %{
             authority_delegable: true,
             kind_allowed: false,
             reversibility_allowed: true
           }
  end

  test "human-required remains absolute under a permissive policy" do
    policy = %{allowed_kinds: ["destructive_op"], allow_non_reversible: true}
    evaluation = evaluate(:human_required, "destructive_op", :irreversible, policy)

    refute evaluation.allowed
    assert evaluation.reasons == [:human_required]
    refute evaluation.checks.authority_delegable
    assert evaluation.checks.kind_allowed
    assert evaluation.checks.reversibility_allowed
  end

  test "allowed and preferred authorities share the same remaining safety gates" do
    for authority <- [:supervisor_allowed, :supervisor_preferred] do
      evaluation = evaluate(authority, "ARCHITECTURE", :reversible, @safe_policy)

      assert evaluation.allowed
      assert evaluation.reasons == []

      assert evaluation.checks == %{
               authority_delegable: true,
               kind_allowed: true,
               reversibility_allowed: true
             }
    end
  end

  test "missing and unallowlisted kinds fail closed" do
    assert evaluate(:supervisor_allowed, nil, :reversible, @safe_policy).reasons == [:kind_missing]

    assert evaluate(:supervisor_allowed, "product", :reversible, @safe_policy).reasons == [
             :kind_not_allowed
           ]
  end

  test "irreversible and partially reversible decisions require the explicit opt-in" do
    for reversibility <- [:irreversible, :partially_reversible] do
      denied = evaluate(:supervisor_allowed, "architecture", reversibility, @safe_policy)
      refute denied.allowed
      assert denied.reasons == [:non_reversible_not_allowed]

      allowed =
        evaluate(:supervisor_allowed, "architecture", reversibility, %{
          @safe_policy
          | allow_non_reversible: true
        })

      assert allowed.allowed
    end
  end

  test "unknown authority, reversibility, or malformed policy fails closed deterministically" do
    assert evaluate(:future_authority, "architecture", :reversible, @safe_policy).reasons == [
             :authority_not_delegable
           ]

    assert evaluate(:supervisor_allowed, "architecture", :future_reversibility, @safe_policy).reasons == [
             :reversibility_not_delegable
           ]

    assert evaluate(:supervisor_allowed, "architecture", :reversible, %{allowed_kinds: :all}).reasons == [
             :kind_not_allowed
           ]
  end

  test "Executor answerability is the narrow reversible authority floor" do
    for authority <- [:supervisor_allowed, :supervisor_preferred] do
      assert DecisionAuthority.executor_answerable?(%{authority: authority, reversibility: :reversible})
      refute DecisionAuthority.executor_answerable?(%{authority: authority, reversibility: :partially_reversible})
    end

    refute DecisionAuthority.executor_answerable?(%{authority: :human_required, reversibility: :reversible})
    refute DecisionAuthority.executor_answerable?(%{authority: :future_authority, reversibility: :reversible})
  end

  defp evaluate(authority, kind, reversibility, policy) do
    DecisionAuthority.evaluate(
      %{authority: authority, kind: kind, reversibility: reversibility},
      policy
    )
  end
end
