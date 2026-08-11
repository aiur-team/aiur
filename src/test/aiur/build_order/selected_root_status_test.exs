defmodule Aiur.BuildOrder.SelectedRootStatusTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{Diagnostic, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.TrackerIdentity

  @now ~U[2026-08-10 12:00:00Z]

  describe "status/1 separates an unavailable provider from a malformed graph" do
    test "a provider_unavailable diagnostic is never reported as structurally invalid" do
      selected = provider_failed_root()

      assert Enum.map(selected.diagnostics, & &1.code) == [:provider_unavailable]
      assert SelectedRoot.status(selected) == :provider_unavailable
      refute SelectedRoot.status(selected) == :structurally_invalid
    end

    test "every provider-sourced diagnostic reports availability, not structure" do
      for code <- [
            :provider_unavailable,
            :provider_schema,
            :call_budget_exhausted,
            :page_budget_exhausted,
            :pagination_mismatch,
            :graphql_partial,
            :invalid_planning_authority,
            :invalid_planning_bounds,
            :missing_github_token
          ] do
        selected = provider_failed_root(code)

        assert SelectedRoot.status(selected) == :provider_unavailable,
               "#{code} must report a provider problem, not a structural one"
      end
    end

    test "a stale provider with no structural defect reports staleness" do
      selected = %{provider_failed_root() | provider: ProviderHealth.new(4, :stale, true)}

      assert SelectedRoot.status(selected) == :provider_stale
    end

    test "a genuinely malformed graph still reports structurally_invalid" do
      # A member with an unusable dependency: a real defect in data we did read.
      malformed =
        Member.new(%{
          identity: identity(2),
          title: "Member",
          url: issue_url(2),
          dependencies: [:malformed]
        })

      selected = SelectedRoot.new(root(), [malformed], healthy())

      assert SelectedRoot.status(selected) == :structurally_invalid
    end

    test "an observed structural defect outranks a provider marked failed to fail closed" do
      # Producers mark the provider unavailable to fail closed on a duplicated
      # identity. That marking must not be mistaken for a transient outage.
      selected = SelectedRoot.new(root(), [], ProviderHealth.new(1, :unavailable, false))
      duplicated = %{selected | diagnostics: [Diagnostic.new(:duplicate_identity)]}

      assert SelectedRoot.status(duplicated) == :structurally_invalid
    end

    test "a complete healthy fetch of a well-formed graph is ready" do
      selected = SelectedRoot.new(root(), [member(2)], healthy())

      assert SelectedRoot.availability(selected, selected.provider) == nil
      assert SelectedRoot.status(selected) == :ready
    end
  end

  describe "availability/2" do
    test "reports a provider verdict from the caller's health rather than the embedded one" do
      selected = SelectedRoot.new(root(), [member(2)], healthy())

      assert SelectedRoot.availability(selected, ProviderHealth.new(9, :stale, true)) == :provider_stale
      assert SelectedRoot.availability(selected, ProviderHealth.new(9, :unavailable, false)) == :provider_unavailable
      assert SelectedRoot.availability(selected, ProviderHealth.new(9, :structurally_invalid, false)) == :structurally_invalid
    end

    test "a non-selected-root value is unavailable, never a structural claim" do
      assert SelectedRoot.availability(nil, healthy()) == :provider_unavailable
    end
  end

  defp provider_failed_root(code \\ :provider_unavailable) do
    # The shape the projection stores after a failed read: no root, no members,
    # a defaulted provider, and one provider-sourced diagnostic.
    selected = SelectedRoot.new(nil, [], nil)
    %{selected | diagnostics: [Diagnostic.new(code)]}
  end

  defp healthy, do: ProviderHealth.new(1, :healthy, true)

  defp root do
    RootSummary.new(%{
      identity: identity(1),
      title: "Build Order",
      url: issue_url(1),
      state: :open,
      state_reason: nil,
      labels: ["build-order"],
      updated_at: @now
    })
  end

  defp member(number) do
    Member.new(%{
      identity: identity(number),
      title: "Ticket #{number}",
      url: issue_url(number),
      state: :open,
      labels: ["complexity:3", "phase:1", "build-lane:plan-graph"],
      updated_at: @now,
      dependencies: []
    })
  end

  defp identity(number) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "ISSUE-#{number}",
      identifier: to_string(number),
      reason: nil
    }
  end

  defp issue_url(number), do: "https://github.com/owner/repo/issues/#{number}"
end
