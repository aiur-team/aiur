defmodule AiurWeb.OperatorControlCenter.Analytics.ScopeResolverTest do
  use ExUnit.Case, async: true

  alias Aiur.Usage.GroupedScopes.Scope
  alias AiurWeb.OperatorControlCenter.Analytics.ScopeResolver

  test "a session scope maps to this_run under the given run identity" do
    assert {:ok, %Scope{kind: :this_run, run_id: "boot-abc"}} = ScopeResolver.usage_scope(:session, "boot-abc")
  end

  test "a session scope with an unusable run identity is refused" do
    assert {:error, :invalid_run_identity} = ScopeResolver.usage_scope(:session, "")
    assert {:error, :invalid_run_identity} = ScopeResolver.usage_scope(:session, nil)
  end

  test "a build order scope carries the analytics run identity instead of its own" do
    scope = %Scope{kind: :intersection, run_id: "stale-boot", ticket_keys: MapSet.new(["999"]), rejected_tickets: 0}
    resolved = %{kind: :build_order, root_number: "77", tickets: MapSet.new(["999"]), total: 1, usage_scope: scope}

    assert {:ok, %Scope{run_id: "analytics-boot", ticket_keys: keys}} =
             ScopeResolver.usage_scope(resolved, "analytics-boot")

    assert MapSet.member?(keys, "999")
  end

  test "a build order scope with a missing run identity is unavailable" do
    scope = %Scope{kind: :intersection, run_id: "stale-boot", ticket_keys: MapSet.new(["999"]), rejected_tickets: 0}
    resolved = %{kind: :build_order, root_number: "77", tickets: MapSet.new(["999"]), total: 1, usage_scope: scope}

    assert {:error, :unavailable} = ScopeResolver.usage_scope(resolved, "")
    assert {:error, :unavailable} = ScopeResolver.usage_scope(resolved, nil)
  end

  test "usage_scope/1 delegates to the live run identity" do
    assert {:ok, %Scope{kind: :this_run, run_id: run_id}} = ScopeResolver.usage_scope(:session)
    assert is_binary(run_id) and run_id != ""
  end

  test "resolve/2 with no Build Order selection is the session scope" do
    assert ScopeResolver.resolve(nil) == :session
  end

  test "telemetry_opts for the session scope adds no ticket filter" do
    assert ScopeResolver.telemetry_opts(:session) == []
  end

  test "telemetry_opts for an unavailable scope excludes every ticket" do
    assert ScopeResolver.telemetry_opts(:unavailable) == [tickets: []]
  end
end
