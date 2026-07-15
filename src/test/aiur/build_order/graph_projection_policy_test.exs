defmodule Aiur.BuildOrder.GraphProjection.PolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, ProviderResult, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Policy
  alias Aiur.TrackerIdentity

  @repository {"owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]

  test "freshness boundaries become due at the exact configured interval" do
    entry = %{last_success_ms: 1_000}

    refute Policy.due?(entry, 60_999, 60_000)
    assert Policy.due?(entry, 61_000, 60_000)
    assert Policy.due?(entry, 61_001, 60_000)

    refute Policy.due?(entry, 15_999, 15_000)
    assert Policy.due?(entry, 16_000, 15_000)

    refute Policy.due?(entry, 5_999, 5_000)
    assert Policy.due?(entry, 6_000, 5_000)
  end

  test "only complete matching candidates pass the atomic publication gate" do
    first = identity(1, "I1")
    second = identity(2, "I2")
    catalog = catalog([root(first)])
    selected = selected(first)

    assert {:ok, ^catalog} =
             Policy.complete_candidate({:ok, ProviderResult.complete(catalog)}, :catalog, @repository)

    assert {:ok, ^selected} =
             Policy.complete_candidate(
               {:ok, ProviderResult.complete(selected)},
               {:selected, first},
               @repository
             )

    assert {:error, :provider_identity_mismatch, nil} =
             Policy.complete_candidate(
               {:ok, ProviderResult.complete(selected)},
               {:selected, second},
               @repository
             )

    assert {:error, :provider_unavailable, nil} =
             Policy.complete_candidate({:ok, ProviderResult.complete(selected)}, :catalog, @repository)

    assert {:error, :schema, %ProviderResult{}} =
             Policy.complete_candidate(
               {:error, ProviderResult.failed(:invalid_connection)},
               :catalog,
               @repository
             )
  end

  test "one malformed catalog root stays visible without weakening repository fencing" do
    malformed = RootSummary.new(%{title: nil, url: nil})
    matching = root(identity(1, "I1"))
    foreign = root(identity(2, "I2", {"other", "repo"}), {"other", "repo"})

    visible = catalog([matching, malformed])

    assert {:ok, ^visible} =
             Policy.complete_candidate({:ok, ProviderResult.complete(visible)}, :catalog, @repository)

    mismatched = catalog([matching, foreign, malformed])

    assert {:error, :provider_identity_mismatch, nil} =
             Policy.complete_candidate({:ok, ProviderResult.complete(mismatched)}, :catalog, @repository)
  end

  test "failures preserve last-known-good data and classify cold state conservatively" do
    candidate = catalog([root(identity(1, "I1"))])

    entry =
      :catalog
      |> Policy.unavailable_entry(0)
      |> Policy.apply_success(candidate, 7, @now, 100)

    failed = Policy.apply_failure(entry, :timeout, @now, DateTime.add(@now, 1, :second), true)

    assert failed.data == candidate
    assert failed.generation == 7
    assert failed.health.state == :stale
    assert failed.health.failure == :timeout
    assert failed.health.retry_count == 1
    assert failed.health.next_retry_at == DateTime.add(@now, 1, :second)

    cold =
      :catalog
      |> Policy.unavailable_entry(0)
      |> Policy.apply_failure(:structurally_invalid, @now, nil, false)

    assert cold.data == nil
    assert cold.generation == :unknown
    assert cold.health.state == :structurally_invalid
    assert cold.health.complete? == false
  end

  test "retry hints are bounded and deterministic" do
    assert Policy.retry_delay_ms(0, 60_000, nil, @now) == 1_000
    assert Policy.retry_delay_ms(1, 60_000, nil, @now) == 2_000
    assert Policy.retry_delay_ms(10, 60_000, nil, @now) == 60_000

    hinted = ProviderResult.failed(:rate_limited, rate_limit: %{retry_after: 12})
    assert Policy.retry_delay_ms(0, 60_000, hinted, @now) == 12_000

    excessive = ProviderResult.failed(:rate_limited, rate_limit: %{retry_after: 999_999})
    assert Policy.retry_delay_ms(0, 60_000, excessive, @now) == 300_000

    past = ProviderResult.failed(:rate_limited, rate_limit: %{reset_at: DateTime.add(@now, -1, :second)})
    assert Policy.retry_delay_ms(2, 60_000, past, @now) == 4_000
  end

  defp catalog(roots), do: Catalog.new(roots, ProviderHealth.new(1, :healthy, true))

  defp selected(identity) do
    SelectedRoot.new(root(identity), [], ProviderHealth.new(1, :healthy, true))
  end

  defp root(identity, {owner, repository} \\ @repository) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order #{identity.identifier}",
      url: "https://github.com/#{owner}/#{repository}/issues/#{identity.identifier}",
      state: "OPEN"
    })
  end

  defp identity(number, provider_id, repository \\ @repository) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => provider_id, "number" => number},
        repository,
        repository
      )

    identity
  end
end
