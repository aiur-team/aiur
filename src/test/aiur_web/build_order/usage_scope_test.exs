defmodule AiurWeb.BuildOrder.UsageScopeTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.{Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.TrackerIdentity
  alias Aiur.Usage.GroupedScopes.Scope
  alias AiurWeb.BuildOrder.{RouteState, UsageScope}

  describe "catalog and non-selected states" do
    test "the catalog route derives no build scope" do
      assert UsageScope.decide(route_state(:catalog, route: :catalog)) == :none
    end

    test "an unresolvable locator is invalid, not empty or zero" do
      assert {:invalid, :invalid_parameter} = UsageScope.decide(route_state(:invalid_parameter))
      assert {:invalid, :not_found} = UsageScope.decide(route_state(:not_found))
      assert {:invalid, :invalid_catalog} = UsageScope.decide(route_state(:invalid_catalog))
      assert {:invalid, :selected_invalid} = UsageScope.decide(route_state(:selected_invalid))
    end

    test "a still-resolving selection is pending, not empty" do
      assert UsageScope.decide(route_state(:awaiting_catalog)) == :pending
      assert UsageScope.decide(route_state(:selected_loading)) == :pending
    end

    test "an unreadable membership is unavailable, not a zero build" do
      assert {:unavailable, :catalog_unavailable} = UsageScope.decide(route_state(:catalog_unavailable))
      assert {:unavailable, :selected_unavailable} = UsageScope.decide(route_state(:selected_unavailable))
    end
  end

  describe "ready membership" do
    test "scopes to exactly the current member set" do
      members = [member(10), member(11)]
      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), members))

      assert {:ready, %Scope{kind: :explicit_ticket_set} = scope, _key, :ready} = UsageScope.decide(state)

      assert MapSet.equal?(
               scope.ticket_keys,
               MapSet.new([github_key(10), github_key(11)])
             )
    end

    test "a member is matched regardless of when its usage was recorded (no joined-at cutoff)" do
      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10)]))
      {:ready, scope, _key, :ready} = UsageScope.decide(state)

      # Any retained cell attributed to a current member matches, so
      # pre-membership usage is included by ticket key alone.
      assert Scope.matches?(scope, %{ticket: github_key(10)})
    end

    test "a removed or non-member ticket is excluded from the scope" do
      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10)]))
      {:ready, scope, _key, :ready} = UsageScope.decide(state)

      refute Scope.matches?(scope, %{ticket: github_key(99)})
    end

    test "repository-qualified keys keep same-number tickets in different repos distinct" do
      other_repo = {"owner", "other"}
      here = member(10)
      there = member_in(10, other_repo)

      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [here, there]))
      {:ready, scope, _key, :ready} = UsageScope.decide(state)

      assert Scope.matches?(scope, %{ticket: github_key(10)})
      assert Scope.matches?(scope, %{ticket: github_key(10, other_repo)})
      assert MapSet.size(scope.ticket_keys) == 2
    end

    test "a stale member graph is still readable but flagged stale, never zeroed" do
      state = route_state(:selected_stale, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10)]))
      assert {:ready, _scope, _key, :stale} = UsageScope.decide(state)
    end
  end

  describe "empty and unscopable builds" do
    test "a selected root with no members is an empty build, not a zero total" do
      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), []))
      assert UsageScope.decide(state) == :empty_build
    end

    test "members that are all non-joinable are unscopable, not empty or zero" do
      unscopable = %Member{identity: %TrackerIdentity{}, title: "Unjoinable"}

      selected = %SelectedRoot{
        root: root_summary(identity(1, "NODE-1")),
        members: [unscopable],
        provider: health(),
        diagnostics: []
      }

      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), selected))
      assert {:unscopable, 1} = UsageScope.decide(state)
    end
  end

  describe "generation-safe membership key" do
    test "this build never shares a key kind with this run" do
      state = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10)]))
      {:ready, _scope, {public, _epoch}, :ready} = UsageScope.decide(state)

      {:ok, run_scope} = Scope.this_run("run-1")
      assert public.kind == :explicit_ticket_set
      assert Scope.public(run_scope).kind == :this_run
    end

    test "the key changes when the member set changes" do
      base = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10)]))
      grown = route_state(:selected, snapshot: selected_snapshot(identity(1, "NODE-1"), [member(10), member(11)]))

      {:ready, _s1, key1, :ready} = UsageScope.decide(base)
      {:ready, _s2, key2, :ready} = UsageScope.decide(grown)
      refute key1 == key2
    end

    test "the key changes when the selected-root authority epoch changes" do
      snap1 = selected_snapshot(identity(1, "NODE-1"), [member(10)], authority_epoch: 1)
      snap2 = selected_snapshot(identity(1, "NODE-1"), [member(10)], authority_epoch: 2)

      {:ready, _s1, key1, :ready} = UsageScope.decide(route_state(:selected, snapshot: snap1))
      {:ready, _s2, key2, :ready} = UsageScope.decide(route_state(:selected, snapshot: snap2))
      refute key1 == key2
    end

    test "the key is stable across projection generation bumps that do not change membership" do
      snap1 = selected_snapshot(identity(1, "NODE-1"), [member(10)], generation: 7)
      snap2 = selected_snapshot(identity(1, "NODE-1"), [member(10)], generation: 8)

      {:ready, _s1, key1, :ready} = UsageScope.decide(route_state(:selected, snapshot: snap1))
      {:ready, _s2, key2, :ready} = UsageScope.decide(route_state(:selected, snapshot: snap2))
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
      url: "https://github.com/#{identity.owner}/#{identity.repository}/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  defp member(number), do: member_in(number, {"owner", "repo"})

  defp member_in(number, repository) do
    Member.new(%{
      identity: identity(number, "NODE-#{repo_tag(repository)}-#{number}", repository),
      title: "Ticket #{number}",
      url: "https://github.com/#{elem(repository, 0)}/#{elem(repository, 1)}/issues/#{number}",
      state: "OPEN",
      state_reason: nil,
      labels: []
    })
  end

  defp github_key(number, repository \\ {"owner", "repo"}) do
    TrackerIdentity.github_key(identity(number, "NODE-#{repo_tag(repository)}-#{number}", repository))
  end

  defp identity(number, provider_id, repository \\ {"owner", "repo"}) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "database_id" => number, "number" => number},
        repository,
        repository
      )

    identity
  end

  defp repo_tag({owner, repository}), do: "#{owner}-#{repository}"

  defp health, do: ProviderHealth.new(1, :healthy, true)
end
