defmodule Aiur.BuildOrder.CatalogTest do
  use ExUnit.Case, async: true

  alias Aiur.{
    BuildOrder.Bounded,
    BuildOrder.Catalog,
    BuildOrder.Dependency,
    BuildOrder.Marker,
    BuildOrder.Member,
    BuildOrder.ProviderHealth,
    BuildOrder.RootSummary,
    BuildOrder.SelectedRoot,
    TrackerIdentity
  }

  @configured {"owner", "repo"}

  test "one malformed root remains visible without hiding valid catalog siblings" do
    valid = root(1)

    invalid =
      RootSummary.new(%{
        identity: identity(2),
        title: "Nested",
        url: issue_url(2),
        parent_identity: identity(1)
      })

    catalog = Catalog.new([invalid, valid], ProviderHealth.new(1, :healthy, true))

    assert catalog.entries == [invalid, valid]
    assert {:structurally_invalid, ^invalid} = Catalog.select(catalog, invalid.identity)
    assert {:ok, ^valid} = Catalog.select(catalog, valid.identity)
  end

  test "selected structural invalidity differs from stale and unavailable provider state" do
    valid = root(1)

    invalid =
      RootSummary.new(%{
        identity: identity(2),
        title: "Nested",
        url: issue_url(2),
        parent_identity: identity(1)
      })

    assert {:provider_stale, ^valid} =
             Catalog.new([valid], ProviderHealth.new(1, :stale, true))
             |> Catalog.select(valid.identity)

    assert {:provider_unavailable, ^valid} =
             Catalog.new([valid], ProviderHealth.new(1, :unavailable, false))
             |> Catalog.select(valid.identity)

    assert {:provider_unavailable, ^valid} =
             Catalog.new([valid], ProviderHealth.new(nil, :healthy, true))
             |> Catalog.select(valid.identity)

    assert {:structurally_invalid, ^invalid} =
             Catalog.new([invalid], ProviderHealth.new(1, :stale, true))
             |> Catalog.select(invalid.identity)
  end

  test "member metadata warnings do not erase an otherwise identifiable member" do
    member =
      Member.new(%{
        identity: identity(1),
        title: "Visible",
        url: issue_url(1),
        labels: ["complexity:1", "complexity:2"]
      })

    assert member.identity == identity(1)
    assert member.title == "Visible"
    assert member.metadata.complexity == :unknown
    assert :ambiguous_complexity in Enum.map(member.metadata.warnings, & &1.code)
  end

  test "an optional marker warning does not erase an otherwise identifiable member" do
    member =
      Member.new(%{
        identity: identity(1),
        title: "Visible",
        url: issue_url(1),
        marker: Marker.parse("<!-- aiur-planning-issue {bad} -->")
      })

    assert member.identity == identity(1)
    assert member.title == "Visible"
    assert :invalid_marker in Enum.map(member.diagnostics, & &1.code)
  end

  test "malformed member or dependency input makes the selected graph structural-invalid" do
    member =
      Member.new(%{
        identity: identity(2),
        title: "Member",
        url: issue_url(2),
        dependencies: [:malformed]
      })

    selected = SelectedRoot.new(root(1), [member, :malformed], ProviderHealth.new(1, :healthy, true))

    assert :invalid_dependency in Enum.map(member.diagnostics, & &1.code)
    refute SelectedRoot.structurally_valid?(selected)
    assert SelectedRoot.status(selected) == :structurally_invalid
  end

  test "a structurally invalid member fails the selected graph closed on its own" do
    missing_identity = Member.new(%{title: "Missing identity", url: issue_url(2)})

    malformed_dependency =
      Member.new(%{
        identity: identity(3),
        title: "Malformed dependency",
        url: issue_url(3),
        dependencies: [:malformed]
      })

    for member <- [missing_identity, malformed_dependency] do
      selected = SelectedRoot.new(root(1), [member], ProviderHealth.new(1, :healthy, true))

      refute SelectedRoot.structurally_valid?(selected)
      assert SelectedRoot.status(selected) == :structurally_invalid
    end
  end

  test "keeps same-repository endpoints native and foreign endpoints nonfetchable" do
    native = Dependency.new(identity(1), identity(2), issue_url(2))
    foreign = foreign_identity(2)
    external = Dependency.new(identity(1), foreign, "https://github.com/other/repo/issues/2")

    assert %{kind: :native, identity: %{provider_id: "I2"}} = native
    assert native.identity == identity(2)

    assert %{kind: :external, identity: nil, url: "https://github.com/other/repo/issues/2"} =
             external

    assert Enum.map(external.diagnostics, & &1.code) == [:external_dependency]

    mismatched_native =
      Dependency.new(identity(1), identity(2), "https://github.com/other/repo/issues/2")

    assert %{kind: :external, identity: nil, url: "https://github.com/other/repo/issues/2"} =
             mismatched_native

    assert Enum.map(mismatched_native.diagnostics, & &1.code) == [:external_dependency]

    unsafe = Dependency.new(identity(1), foreign, "https://token@github.com/other/repo/issues/2")
    assert unsafe.url == nil
    assert Enum.map(unsafe.diagnostics, & &1.code) == [:external_dependency, :unsafe_external_url]

    for url <- ["http://github.com/other/repo/issues/2", "https://github.com/other/repo/issues/2?token=secret", "https://github.com/other/repo/issues/2#secret"] do
      assert Bounded.github_url(url) == :error
    end

    missing_identity = Dependency.new(identity(1), nil, issue_url(2))
    assert missing_identity.kind == :unknown
    assert Enum.map(missing_identity.diagnostics, & &1.code) == [:invalid_identity]
  end

  test "catalog root overflow receives a root-specific diagnostic" do
    catalog = Catalog.new(List.duplicate(root(1), 101), ProviderHealth.new(1, :healthy, true))

    assert length(catalog.entries) == 100
    assert [%{code: :catalog_overflow}] = catalog.diagnostics
  end

  test "catalog lookup uses the immutable identity rather than a mutable display number" do
    valid = root(1)
    relocated = %{valid.identity | identifier: "999"}
    catalog = Catalog.new([valid], ProviderHealth.new(1, :healthy, true))

    assert {:ok, ^valid} = Catalog.select(catalog, relocated)
  end

  test "catalog projections remain body-free and contain no detail-cache contract" do
    root = root(1)
    catalog = Catalog.new([root], ProviderHealth.new(1, :healthy, true))

    refute Map.has_key?(root, :description)
    refute Map.has_key?(root, :detail)
    refute Map.has_key?(catalog, :ticket_detail)
    refute Map.has_key?(catalog, :subscription)
  end

  test "record constructors reject untyped inputs without raising" do
    assert %{identity: nil, diagnostics: diagnostics} = RootSummary.new(:invalid)
    assert :invalid_identity in Enum.map(diagnostics, & &1.code)

    assert %{identity: nil, lifecycle: %{state: :unknown}} = Member.new(:invalid)
  end

  test "bounds selected roots to zero through one hundred direct members" do
    root = root(1)
    member = Member.new(%{identity: identity(2), title: "Member", url: issue_url(2)})

    assert SelectedRoot.new(root, [], ProviderHealth.new(1, :healthy, true)).members == []

    assert length(SelectedRoot.new(root, [member], ProviderHealth.new(1, :healthy, true)).members) ==
             1

    assert length(
             SelectedRoot.new(
               root,
               List.duplicate(member, 100),
               ProviderHealth.new(1, :healthy, true)
             ).members
           ) == 100

    selected =
      SelectedRoot.new(root, List.duplicate(member, 101), ProviderHealth.new(1, :healthy, true))

    assert length(selected.members) == 100
    assert [%{code: :member_overflow}] = selected.diagnostics
    refute SelectedRoot.structurally_valid?(selected)
    assert SelectedRoot.status(selected) == :structurally_invalid

    assert SelectedRoot.status(SelectedRoot.new(root, [], ProviderHealth.new(1, :stale, true))) == :provider_stale
  end

  defp root(number),
    do:
      RootSummary.new(%{
        identity: identity(number),
        title: "Root #{number}",
        url: issue_url(number)
      })

  defp identity(number) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => "I#{number}", "number" => number},
        @configured,
        @configured
      )

    identity
  end

  defp foreign_identity(number) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => "Foreign#{number}", "number" => number},
        {"other", "repo"},
        {"other", "repo"}
      )

    identity
  end

  defp issue_url(number), do: "https://github.com/owner/repo/issues/#{number}"
end
