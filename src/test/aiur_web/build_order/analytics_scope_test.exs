defmodule AiurWeb.BuildOrder.AnalyticsScopeTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.{Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.{AnalyticsScope, RouteState}

  describe "catalog and non-selected states" do
    test "the catalog route derives no telemetry scope" do
      assert AnalyticsScope.decide(route_state(:catalog, route: :catalog)) == :none
    end

    test "an unresolvable locator is invalid, not an empty build" do
      assert {:invalid, :invalid_parameter} = AnalyticsScope.decide(route_state(:invalid_parameter))
      assert {:invalid, :not_found} = AnalyticsScope.decide(route_state(:not_found))
      assert {:invalid, :invalid_catalog} = AnalyticsScope.decide(route_state(:invalid_catalog))
      assert {:invalid, :selected_invalid} = AnalyticsScope.decide(route_state(:selected_invalid))
    end

    test "a still-resolving selection is pending, so the pane waits rather than showing zero" do
      assert AnalyticsScope.decide(route_state(:awaiting_catalog)) == :pending
      assert AnalyticsScope.decide(route_state(:selected_loading)) == :pending
    end

    test "an unreadable membership is unavailable, not a build that burned nothing" do
      assert {:unavailable, :catalog_unavailable} = AnalyticsScope.decide(route_state(:catalog_unavailable))
      assert {:unavailable, :selected_unavailable} = AnalyticsScope.decide(route_state(:selected_unavailable))
    end
  end

  describe "ready membership" do
    test "scopes to the member numbers telemetry actually records" do
      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10), member(11)]))

      assert {:ready, scope, _key, :ready} = AnalyticsScope.decide(state)
      assert MapSet.equal?(scope.tickets, MapSet.new(["10", "11"]))
      assert scope.total == 2
      assert scope.rejected == 0
    end

    test "membership is re-derived live, so a ticket that joins later contributes the telemetry it already wrote" do
      # There is no joined-at cutoff: the scope is the current member set, and
      # every record keyed to a current member is in scope regardless of when it
      # was written.
      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10)]))
      {:ready, scope, _key, :ready} = AnalyticsScope.decide(state)

      assert MapSet.member?(scope.tickets, "10")
    end

    test "a non-member ticket is excluded so another build's cost never lands here" do
      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10)]))
      {:ready, scope, _key, :ready} = AnalyticsScope.decide(state)

      refute MapSet.member?(scope.tickets, "99")
    end

    test "the burn-up denominator counts every member, including ones with no joinable identity" do
      # Otherwise a build reads as complete because the tickets that cannot be
      # measured silently leave the denominator.
      members = [member(10), %Member{identity: %TrackerIdentity{}, title: "Unjoinable"}]
      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), members))

      assert {:ready, scope, _key, :ready} = AnalyticsScope.decide(state)
      assert scope.total == 2
      assert scope.rejected == 1
      assert MapSet.size(scope.tickets) == 1
    end

    test "a stale member graph is still readable but flagged stale, never zeroed" do
      state = route_state(:selected_stale, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10)]))

      assert {:ready, _scope, _key, :stale} = AnalyticsScope.decide(state)
    end

    test "a stale catalog with a resolved root is readable; without one the membership is unavailable" do
      resolved = route_state(:catalog_stale, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10)]))
      assert {:ready, _scope, _key, :stale} = AnalyticsScope.decide(resolved)

      assert {:unavailable, :catalog_stale} = AnalyticsScope.decide(route_state(:catalog_stale))
    end
  end

  describe "empty and unscopable builds" do
    test "a selected root with no members is an empty build, not a zero-cost build" do
      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), []))

      assert AnalyticsScope.decide(state) == :empty_build
    end

    test "members that are all non-joinable are unscopable rather than coerced to bare numbers" do
      unscopable = %Member{identity: %TrackerIdentity{}, title: "Unjoinable"}

      selected = %SelectedRoot{
        root: root_summary(identity(1, "NODE-1")),
        members: [unscopable],
        provider: health(),
        diagnostics: []
      }

      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), selected))

      assert {:unscopable, 1} = AnalyticsScope.decide(state)
    end
  end

  describe "membership key" do
    test "the key changes when the member set changes so a stale read is discarded" do
      base = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10)]))
      grown = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10), member(11)]))

      {:ready, _s1, key1, :ready} = AnalyticsScope.decide(base)
      {:ready, _s2, key2, :ready} = AnalyticsScope.decide(grown)

      refute key1 == key2
    end

    test "the key changes when the selected-root authority epoch changes" do
      snap1 = selected_snapshot(identity(1, "NODE-1"), [member(10)], authority_epoch: 1)
      snap2 = selected_snapshot(identity(1, "NODE-1"), [member(10)], authority_epoch: 2)

      {:ready, _s1, key1, :ready} = AnalyticsScope.decide(route_state(:selected, snapshot: snap1))
      {:ready, _s2, key2, :ready} = AnalyticsScope.decide(route_state(:selected, snapshot: snap2))

      refute key1 == key2
    end

    test "the key survives projection generation bumps that do not change membership" do
      # The graph projection advances its generation on every successful poll;
      # keying on it would re-parse the whole telemetry stream for no reason.
      snap1 = selected_snapshot(identity(1, "NODE-1"), [member(10)], generation: 7)
      snap2 = selected_snapshot(identity(1, "NODE-1"), [member(10)], generation: 8)

      {:ready, _s1, key1, :ready} = AnalyticsScope.decide(route_state(:selected, snapshot: snap1))
      {:ready, _s2, key2, :ready} = AnalyticsScope.decide(route_state(:selected, snapshot: snap2))

      assert key1 == key2
    end

    test "member ordering does not change the key" do
      one = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10), member(11)]))
      other = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(11), member(10)]))

      {:ready, _s1, key1, :ready} = AnalyticsScope.decide(one)
      {:ready, _s2, key2, :ready} = AnalyticsScope.decide(other)

      assert key1 == key2
    end
  end

  # --- fixtures ------------------------------------------------------------

  defp route_state(status, opts \\ []) do
    %RouteState{
      request_epoch: "test",
      route: Keyword.get(opts, :route, :selected),
      status: status,
      selected_identity: selected_identity(opts),
      selected_snapshot: Keyword.get(opts, :snapshot)
    }
  end

  defp selected_identity(opts) do
    case Keyword.get(opts, :snapshot) do
      %Snapshot{scope: {:selected, identity}} -> identity
      _no_snapshot -> Keyword.get(opts, :identity)
    end
  end

  defp selected_snapshot(identity, members_or_data, opts \\ [])

  defp selected_snapshot(identity, %SelectedRoot{} = data, opts) do
    %Snapshot{
      scope: {:selected, identity},
      repository: {"owner", "repo"},
      authority_epoch: Keyword.get(opts, :authority_epoch, 1),
      generation: Keyword.get(opts, :generation, 1),
      data: data,
      health: health()
    }
  end

  defp selected_snapshot(identity, members, opts) when is_list(members) do
    data = SelectedRoot.new(root_summary(identity), members, health())
    selected_snapshot(identity, data, opts)
  end

  defp root_summary(identity) do
    RootSummary.new(%{
      identity: identity,
      title: "Root #{identity.identifier}",
      url: "https://github.com/owner/repo/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  defp member(number) do
    Member.new(%{
      identity: identity(number, "NODE-#{number}"),
      title: "Ticket #{number}",
      url: "https://github.com/owner/repo/issues/#{number}",
      state: "OPEN",
      state_reason: nil,
      labels: []
    })
  end

  defp identity(number, node_id) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: node_id,
      database_id: number,
      identifier: Integer.to_string(number),
      reason: nil
    }
  end

  defp health, do: %ProviderHealth{}
end
