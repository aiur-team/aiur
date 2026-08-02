defmodule Aiur.Usage.GroupedScopes.ScopeTest do
  use ExUnit.Case, async: true

  alias Aiur.TestSupport.GroupedScopes, as: Support
  alias Aiur.TrackerIdentity
  alias Aiur.Usage.GroupedScopes.Scope

  describe "typed construction" do
    test "this_run requires a non-empty opaque run identity" do
      assert {:ok, %Scope{kind: :this_run, run_id: "run-A"}} = Scope.this_run("run-A")
      assert {:error, :invalid_run_identity} = Scope.this_run("")
      assert {:error, :invalid_run_identity} = Scope.this_run(1115)
      assert {:error, :invalid_run_identity} = Scope.this_run(nil)
    end

    test "explicit_ticket_set keys only joinable identities and counts the rest" do
      {:ok, scope} = Scope.explicit_ticket_set([Support.identity(1), 1128, "1128", nil])

      assert scope.kind == :explicit_ticket_set
      assert scope.rejected_tickets == 3
      assert MapSet.to_list(scope.ticket_keys) == [TrackerIdentity.github_key(Support.identity(1))]
    end

    test "intersection requires both a run identity and a ticket list" do
      {:ok, scope} = Scope.intersection("run-A", [Support.identity(1)])
      assert scope.kind == :intersection
      assert scope.run_id == "run-A"

      assert {:error, :invalid_run_identity} = Scope.intersection("", [Support.identity(1)])
      assert {:error, :invalid_ticket_set} = Scope.intersection("run-A", :not_a_list)
    end
  end

  describe "selection semantics" do
    test "this_run matches on run identity only" do
      {:ok, scope} = Scope.this_run("run-A")
      assert Scope.matches?(scope, %{run_id: "run-A", ticket: :unknown})
      refute Scope.matches?(scope, %{run_id: "run-B", ticket: :unknown})
    end

    test "explicit_ticket_set matches members regardless of run (pre-membership usage)" do
      key = TrackerIdentity.github_key(Support.identity(1))
      {:ok, scope} = Scope.explicit_ticket_set([Support.identity(1)])

      assert Scope.matches?(scope, %{run_id: "any-run", ticket: key})
      refute Scope.matches?(scope, %{run_id: "any-run", ticket: :unknown})
    end

    test "intersection requires run AND ticket membership together" do
      key = TrackerIdentity.github_key(Support.identity(1))
      {:ok, scope} = Scope.intersection("run-A", [Support.identity(1)])

      assert Scope.matches?(scope, %{run_id: "run-A", ticket: key})
      refute Scope.matches?(scope, %{run_id: "run-B", ticket: key})
      refute Scope.matches?(scope, %{run_id: "run-A", ticket: :unknown})
    end
  end

  describe "public description" do
    test "empty explicit set is a valid, selectable-empty scope" do
      {:ok, scope} = Scope.explicit_ticket_set([])
      public = Scope.public(scope)

      assert public.status == :empty
      refute Scope.selectable?(scope)
    end

    test "a run scope is always selectable" do
      {:ok, scope} = Scope.this_run("run-A")
      assert Scope.public(scope).status == :scoped
      assert Scope.selectable?(scope)
    end
  end
end
