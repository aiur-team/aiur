defmodule AiurWeb.BuildOrder.RouteStateTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.RouteState

  describe "canonical root locators" do
    test "accepts only bounded positive decimal issue numbers" do
      for identifier <- ["1", "42", "9999999999999999999"] do
        assert {:ok, ^identifier} = RouteState.parse_root(identifier)
      end

      for identifier <- [nil, 1, "", "0", "01", "+1", "-1", " 1", "1 ", "1.0", "1/2", "10000000000000000000"] do
        assert :error = RouteState.parse_root(identifier)
      end
    end

    test "retains an invalid selected URL as a controlled state without activating a root" do
      state = RouteState.new("mount-1")
      {state, effects} = RouteState.navigate(state, "01")

      assert effects == []
      assert RouteState.status(state) == :invalid_parameter
      assert RouteState.selected_identity(state) == nil
      assert RouteState.root_identifier(state) == nil
    end
  end

  describe "catalog-backed identity resolution" do
    test "keeps a locator pending until a catalog supplies the opaque identity" do
      identity = identity(42, "NODE-42")
      state = RouteState.new("mount-1")
      {state, []} = RouteState.navigate(state, "42")

      assert RouteState.status(state) == :awaiting_catalog
      assert RouteState.selected_identity(state) == nil

      {state, effects} = RouteState.put_catalog(state, catalog_snapshot([root(identity)], 1, :healthy))

      assert effects == [{:activate, identity}]
      assert RouteState.status(state) == :selected_loading
      assert RouteState.selected_identity(state) == identity
    end

    test "uses stale catalog LKG but distinguishes cold unavailable and healthy not found" do
      identity = identity(42, "NODE-42")
      {state, []} = RouteState.new("mount-1") |> RouteState.navigate("42")

      {cold, []} = RouteState.put_catalog(state, catalog_snapshot(nil, :unknown, :unavailable))
      assert RouteState.status(cold) == :catalog_unavailable

      {stale, [{:activate, ^identity}]} =
        RouteState.put_catalog(cold, catalog_snapshot([root(identity)], 1, :stale))

      assert RouteState.status(stale) == :selected_loading

      {missing, [{:deactivate, ^identity}]} =
        RouteState.put_catalog(stale, catalog_snapshot([], 2, :healthy))

      assert RouteState.status(missing) == :not_found
      assert RouteState.selected_identity(missing) == nil
    end

    test "one malformed entry cannot hide a valid sibling" do
      identity = identity(7, "NODE-7")
      malformed = RootSummary.new(%{})
      {state, []} = RouteState.new("mount-1") |> RouteState.navigate("7")

      {state, effects} = RouteState.put_catalog(state, catalog_snapshot([malformed, root(identity)], 1, :healthy))

      assert effects == [{:activate, identity}]
      assert RouteState.selected_identity(state) == identity
    end

    test "duplicate joinable number matches fail closed" do
      first = identity(7, "NODE-7-A")
      second = identity(7, "NODE-7-B")
      {state, []} = RouteState.new("mount-1") |> RouteState.navigate("7")

      {state, effects} = RouteState.put_catalog(state, catalog_snapshot([root(first), root(second)], 1, :healthy))

      assert effects == []
      assert RouteState.status(state) == :invalid_catalog
      assert RouteState.selected_identity(state) == nil
    end

    test "switching roots deactivates the old identity before activating the new one" do
      first = identity(7, "NODE-7")
      second = identity(8, "NODE-8")

      {state, []} = RouteState.new("mount-1") |> RouteState.put_catalog(catalog_snapshot([root(first), root(second)], 1, :healthy))
      {state, [{:activate, ^first}]} = RouteState.navigate(state, "7")
      {state, effects} = RouteState.navigate(state, "8")

      assert effects == [{:deactivate, first}, {:activate, second}]
      assert RouteState.selected_identity(state) == second

      {state, effects} = RouteState.navigate(state, nil)
      assert effects == [{:deactivate, second}]
      assert RouteState.status(state) == :catalog
      assert RouteState.selected_identity(state) == nil
    end
  end

  describe "selected projection generations" do
    setup do
      identity = identity(42, "NODE-42")
      {state, []} = RouteState.new("mount-1") |> RouteState.put_catalog(catalog_snapshot([root(identity)], 1, :healthy))
      {state, [{:activate, ^identity}]} = RouteState.navigate(state, "42")
      %{identity: identity, state: state}
    end

    test "accepts one newer data generation and same-generation health without replacing data", %{identity: identity, state: state} do
      selected = selected_root(identity)
      ready = selected_snapshot(identity, selected, 3, :healthy)
      {state, :generation} = RouteState.put_selected(state, ready)

      assert RouteState.dom_generation(state) == 1
      assert RouteState.selected_snapshot(state) == ready
      assert RouteState.status(state) == :selected

      health_only = selected_snapshot(identity, nil, 3, :stale, refreshing?: true)
      {state, :health} = RouteState.put_selected(state, health_only)

      assert RouteState.dom_generation(state) == 1
      assert RouteState.selected_snapshot(state).data == selected
      assert RouteState.selected_snapshot(state).health.state == :stale
      assert RouteState.selected_snapshot(state).health.refreshing?
      assert RouteState.status(state) == :selected_stale
    end

    test "rejects older and wrong-root snapshots", %{identity: identity, state: state} do
      {state, :generation} = RouteState.put_selected(state, selected_snapshot(identity, selected_root(identity), 3, :healthy))
      other = identity(43, "NODE-43")

      assert {^state, :ignored} = RouteState.put_selected(state, selected_snapshot(identity, selected_root(identity), 2, :healthy))
      assert {^state, :ignored} = RouteState.put_selected(state, selected_snapshot(other, selected_root(other), 4, :healthy))
    end

    test "replaces selected data only for an explicit local pack refresh", %{identity: identity, state: state} do
      {state, :generation} = RouteState.put_selected(state, selected_snapshot(identity, selected_root(identity), 3, :healthy))

      replacement =
        identity
        |> selected_root()
        |> Map.update!(:root, &%{&1 | title: "Edited pack title"})

      {state, :generation} = RouteState.replace_selected(state, selected_snapshot(identity, replacement, 3, :healthy))

      assert RouteState.dom_generation(state) == 2
      assert RouteState.selected_snapshot(state).data.root.title == "Edited pack title"
    end

    test "distinguishes selected unavailable, stale, and structural-invalid snapshots", %{
      identity: identity,
      state: state
    } do
      {state, :generation} = RouteState.put_selected(state, selected_snapshot(identity, nil, 1, :unavailable))
      assert RouteState.status(state) == :selected_unavailable

      {state, :generation} = RouteState.put_selected(state, selected_snapshot(identity, nil, 2, :stale))
      assert RouteState.status(state) == :selected_stale

      {state, :generation} = RouteState.put_selected(state, selected_snapshot(identity, nil, 3, :structurally_invalid))
      assert RouteState.status(state) == :selected_invalid
    end

    test "marks only the exact empty selected scope unavailable after demand failure", %{
      identity: identity,
      state: state
    } do
      assert RouteState.status(state) == :selected_loading
      failed = RouteState.demand_failed(state, identity)
      assert RouteState.status(failed) == :selected_unavailable

      other = identity(43, "NODE-43")
      assert RouteState.demand_failed(state, other) == state

      {ready, :generation} = RouteState.put_selected(state, selected_snapshot(identity, selected_root(identity), 1, :healthy))
      assert RouteState.demand_failed(ready, identity) == ready
    end

    test "classifies structurally invalid data even when transport health is healthy", %{
      identity: identity,
      state: state
    } do
      invalid = SelectedRoot.new(RootSummary.new(%{}), [], health(1, :healthy))

      {state, :generation} = RouteState.put_selected(state, selected_snapshot(identity, invalid, 1, :healthy))

      assert RouteState.status(state) == :selected_invalid
      assert RouteState.selected_snapshot(state).data == invalid
    end

    test "scoped async tokens expire on root and planning generation changes", %{identity: identity, state: state} do
      first = RouteState.async_token(state, :sources)
      assert RouteState.current_async?(state, first, :sources)

      {state, :generation} = RouteState.put_selected(state, selected_snapshot(identity, selected_root(identity), 1, :healthy))
      refute RouteState.current_async?(state, first, :sources)

      second = RouteState.async_token(state, :sources)
      assert RouteState.current_async?(state, second, :sources)

      {state, [{:deactivate, ^identity}]} = RouteState.navigate(state, nil)
      refute RouteState.current_async?(state, second, :sources)
    end

    test "reset retains the URL locator while invalidating current scope", %{identity: identity, state: state} do
      {state, :generation} = RouteState.put_selected(state, selected_snapshot(identity, selected_root(identity), 1, :healthy))
      token = RouteState.async_token(state, :sources)

      {state, effects} = RouteState.reset(state)

      assert effects == [{:deactivate, identity}]
      assert RouteState.root_identifier(state) == "42"
      assert RouteState.status(state) == :awaiting_catalog
      assert RouteState.selected_identity(state) == nil
      assert RouteState.selected_snapshot(state) == nil
      refute RouteState.current_async?(state, token, :sources)
    end
  end

  defp catalog_snapshot(entries, generation, state) do
    data =
      case entries do
        nil -> nil
        entries -> Catalog.new(entries, health(generation, state))
      end

    %Snapshot{
      scope: :catalog,
      repository: repository(),
      generation: generation,
      data: data,
      health: health(generation, state)
    }
  end

  defp selected_snapshot(identity, data, generation, state, opts \\ []) do
    %Snapshot{
      scope: {:selected, identity},
      repository: repository(),
      generation: generation,
      data: data,
      health: health(generation, state, opts)
    }
  end

  defp selected_root(identity) do
    SelectedRoot.new(root(identity), [], health(1, :healthy))
  end

  defp root(identity) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order #{identity.identifier}",
      url: "https://github.com/owner/repo/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  defp health(generation, state, opts \\ []) do
    ProviderHealth.new(generation, state, state == :healthy, opts)
  end

  defp identity(number, provider_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "database_id" => number, "number" => number},
        repository(),
        repository()
      )

    identity
  end

  defp repository, do: {"owner", "repo"}
end
