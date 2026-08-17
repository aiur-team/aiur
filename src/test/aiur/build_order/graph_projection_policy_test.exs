defmodule Aiur.BuildOrder.GraphProjection.PolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{Catalog, Diagnostic, ProviderHealth, ProviderResult, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.{Options, Policy}
  alias Aiur.TrackerIdentity

  @repository {"owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]

  test "catalog freshness becomes due at exact boundaries" do
    baseline_ms = 1_000
    policy = Options.new(clock_ms: fn -> baseline_ms end).policy
    entry = %{last_success_ms: baseline_ms}

    assert policy.catalog_refresh_ms == 60_000

    interval = policy.catalog_refresh_ms
    refute Policy.due?(entry, baseline_ms + interval - 1, interval)
    assert Policy.due?(entry, baseline_ms + interval, interval)
    assert Policy.due?(entry, baseline_ms + interval + 1, interval)
  end

  # The catalog is the only scope left with an interval. A selected root is read
  # when a writer or an explicit refresh asks for it, so a policy that still
  # carried a selected or demand interval would mean the viewer-driven refresh
  # had come back.
  test "the policy carries no viewer-driven interval" do
    policy = Options.new(clock_ms: fn -> 0 end).policy

    refute Map.has_key?(policy, :selected_refresh_ms)
    refute Map.has_key?(policy, :demand_refresh_ms)
  end

  test "configured refresh interval preserves the same deterministic boundary" do
    baseline_ms = 10_000
    configured_ms = 120_000

    policy = Options.policy_options(catalog_refresh_ms: configured_ms)

    entry = %{last_success_ms: baseline_ms}

    assert policy.catalog_refresh_ms == configured_ms
    refute Policy.due?(entry, baseline_ms + configured_ms - 1, configured_ms)
    assert Policy.due?(entry, baseline_ms + configured_ms, configured_ms)
    assert Policy.due?(entry, baseline_ms + configured_ms + 1, configured_ms)
  end

  # A configuration still carrying the deleted viewer cadences must be inert
  # rather than fatal: the keys are ignored, not honoured and not rejected.
  test "the deleted viewer cadences are ignored if still configured" do
    policy =
      Options.policy_options(
        catalog_refresh_ms: 60_000,
        selected_refresh_ms: 10_000,
        demand_refresh_ms: 10_001
      )

    assert policy.catalog_refresh_ms == 60_000
    refute Map.has_key?(policy, :selected_refresh_ms)
    refute Map.has_key?(policy, :demand_refresh_ms)
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

  # `Result.failure/3` records the precise fault it observed. Folding every one
  # of them into `:provider_unavailable` told the operator GitHub was down when
  # the read had actually returned an inconsistent page, a repeated identity or
  # a misconfigured authority (#1777).
  test "a named provider fault keeps its own class instead of a generic outage" do
    for reason <- [
          :pagination_mismatch,
          :duplicate_identity,
          :provider_identity_mismatch,
          :invalid_planning_bounds,
          :invalid_planning_authority,
          :connection_overflow,
          :graphql_partial
        ] do
      assert Policy.failure_class(reason) == reason

      assert {:error, ^reason, %ProviderResult{}} =
               Policy.complete_candidate(
                 {:error, ProviderResult.failed(reason)},
                 {:selected, identity(1, "I1")},
                 @repository
               )
    end

    assert Policy.failure_class(:missing_github_token) == :permission
    assert Policy.failure_class(:provider_schema) == :schema

    # A genuinely malformed graph must still report as malformed.
    assert Policy.failure_class(:structurally_invalid) == :structurally_invalid
  end

  test "a provider-sourced candidate defect is reported as a read fault, not a malformed graph" do
    first = identity(1, "I1")

    provider_degraded = %{
      selected(first)
      | diagnostics: [Diagnostic.new(:pagination_mismatch)]
    }

    assert {:error, :pagination_mismatch, nil} =
             Policy.complete_candidate(
               {:ok, ProviderResult.complete(provider_degraded)},
               {:selected, first},
               @repository
             )

    # The reverse direction still holds: a defect observed in data we did read
    # is a real claim about the operator's Build Order.
    structurally_broken = %{selected(first) | diagnostics: [Diagnostic.new(:duplicate_identity)]}

    assert {:error, :structurally_invalid, nil} =
             Policy.complete_candidate(
               {:ok, ProviderResult.complete(structurally_broken)},
               {:selected, first},
               @repository
             )

    malformed_root =
      SelectedRoot.new(
        RootSummary.new(%{identity: first, title: nil, url: nil}),
        [],
        ProviderHealth.new(1, :healthy, true)
      )

    assert {:error, :structurally_invalid, nil} =
             Policy.complete_candidate(
               {:ok, ProviderResult.complete(malformed_root)},
               {:selected, first},
               @repository
             )
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
