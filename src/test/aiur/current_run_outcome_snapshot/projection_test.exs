defmodule Aiur.CurrentRunOutcomeSnapshot.ProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.{CurrentRunOutcomeSnapshot, RecentMerge, TrackerIdentity}
  alias Aiur.CurrentRunOutcomeSnapshot.Projection

  test "associates a merge only through repository, branch, membership, and run window" do
    snapshot = CurrentRunOutcomeSnapshot.project(inputs())

    assert snapshot.version == 1
    assert snapshot.state == :healthy
    assert snapshot.completeness == :complete
    assert snapshot.health == %{status: :healthy, reasons: []}
    assert snapshot.repository == "owner/repo"
    assert snapshot.counts == %{input: 1, invalid: 0, deduplicated: 1, qualified: 1, returned: 1}

    assert [outcome] = snapshot.outcomes
    assert outcome.id == "owner/repo#32"
    assert outcome.member.identifier == "32"

    assert outcome.association == %{
             version: 1,
             basis: :configured_repository_branch_locator_unique_membership_run_window
           }

    assert outcome.run.id == "run-1"
  end

  test "observation provenance never becomes qualification evidence" do
    merge = merge(32, observed_run_id: "another-run", live_observed?: true, backfilled?: false)

    snapshot = CurrentRunOutcomeSnapshot.project(inputs(merges: [merge]))

    assert snapshot.state == :healthy
    assert [outcome] = snapshot.outcomes
    assert outcome.observation.observed_run_id == "another-run"
    assert outcome.observation.live_observed?
    refute outcome.observation.backfilled?
  end

  test "reports each conservative exclusion reason" do
    merges = [
      merge(32, repository: "other/repo", id: "other/repo#32"),
      merge(32, head_ref: "feature/not-a-ticket", id: "owner/repo#40", number: 40),
      merge(32, merged_at: ~U[2026-07-17 09:59:59Z], id: "owner/repo#41", number: 41),
      merge(99, id: "owner/repo#99")
    ]

    snapshot = CurrentRunOutcomeSnapshot.project(inputs(merges: merges))

    assert snapshot.state == :healthy_empty
    assert snapshot.completeness == :complete

    assert snapshot.exclusions == %{
             repository_mismatch: 1,
             noncanonical_branch: 1,
             outside_run_window: 1,
             not_current_member: 1,
             ambiguous_identity: 0
           }
  end

  test "requires a unique repository-qualified membership identity" do
    members = [member(identity(32)), member(identity(32, provider_id: "NODE-other"))]

    snapshot = CurrentRunOutcomeSnapshot.project(inputs(members: members))

    assert snapshot.state == :healthy_empty
    assert snapshot.exclusions.ambiguous_identity == 1
    assert snapshot.outcomes == []
  end

  test "invalid merge entries make completeness partial instead of disappearing" do
    snapshot = CurrentRunOutcomeSnapshot.project(inputs(merges: [:malformed, merge(32)]))

    assert snapshot.state == :partial
    assert snapshot.completeness == :partial
    assert snapshot.counts.invalid == 1
    assert snapshot.counts.qualified == 1
    assert :invalid_merge_entries in snapshot.health.reasons
  end

  test "non-fresh membership never yields a healthy complete snapshot" do
    for freshness <- [%{status: :unknown}, :unavailable, :partial] do
      snapshot = CurrentRunOutcomeSnapshot.project(inputs(membership_freshness: freshness))

      assert snapshot.state == :partial
      assert snapshot.completeness == :partial
      assert snapshot.freshness.status in [:unknown, :unavailable, :partial]
      refute snapshot.health.status == :healthy
    end
  end

  test "stale membership has a distinct public state" do
    snapshot = CurrentRunOutcomeSnapshot.project(inputs(membership_freshness: %{status: :stale}))

    assert snapshot.state == :stale
    assert snapshot.completeness == :partial
    assert snapshot.health.status == :partial
    assert :membership_stale in snapshot.health.reasons
  end

  test "unavailable required sources return a bounded empty envelope" do
    snapshot = CurrentRunOutcomeSnapshot.project(inputs(membership_health: {:unavailable, :read_failed}))

    assert snapshot.state == :unavailable
    assert snapshot.completeness == :unavailable
    assert snapshot.outcomes == []
    assert snapshot.counts.returned == 0
    assert snapshot.health.status == :unavailable
    assert :membership_unavailable in snapshot.health.reasons
  end

  test "readable merge-store persistence failures retain bounded outcomes" do
    for health <- [{:append_failed, :disk_full}, {:compaction_failed, :disk_full}] do
      snapshot = CurrentRunOutcomeSnapshot.project(inputs(merge_health: health))

      assert snapshot.state == :partial
      assert snapshot.completeness == :partial
      assert snapshot.counts.qualified == 1
      assert snapshot.counts.returned == 1
      assert snapshot.health.status == :partial
      assert :merge_source_degraded in snapshot.health.reasons
      refute :merge_source_unavailable in snapshot.health.reasons
    end
  end

  test "orders newest first and makes result caps explicit" do
    members = [member(identity(32)), member(identity(33))]

    snapshot =
      CurrentRunOutcomeSnapshot.project(
        inputs(
          members: members,
          merges: [
            merge(32, merged_at: ~U[2026-07-17 11:00:00Z]),
            merge(33, merged_at: ~U[2026-07-17 11:30:00Z])
          ],
          limit: 1
        )
      )

    assert snapshot.state == :partial
    assert snapshot.completeness == :partial
    assert snapshot.truncated?
    assert snapshot.counts.qualified == 2
    assert snapshot.counts.returned == 1
    assert [outcome] = snapshot.outcomes
    assert outcome.number == 33
    assert :result_truncated in snapshot.health.reasons
  end

  test "membership signatures are deterministic and repository-qualified" do
    alpha = identity(32)
    beta = identity(33)

    assert Projection.membership_signature([alpha, beta]) ==
             Projection.membership_signature([member(beta), member(alpha)])

    refute Projection.membership_signature([alpha]) ==
             Projection.membership_signature([
               identity(32, repository: "another", provider_id: "NODE-32")
             ])
  end

  defp inputs(opts \\ []) do
    members = Keyword.get(opts, :members, [member(identity(32))])
    merges = Keyword.get(opts, :merges, [merge(32)])

    %{
      run: %{
        id: "run-1",
        started_at: ~U[2026-07-17 10:00:00Z],
        observed_at: ~U[2026-07-17 12:00:00Z],
        valid?: true
      },
      membership: %{
        run_id: "run-1",
        generation: 7,
        health: Keyword.get(opts, :membership_health, :healthy),
        freshness: Keyword.get(opts, :membership_freshness, %{status: :fresh}),
        truncated?: false,
        members: members
      },
      recent_merges: %{
        generation: 9,
        health: Keyword.get(opts, :merge_health, :writable),
        reconciliation: %{status: :complete, partial?: false, pages_fetched: 1},
        merges: merges
      },
      configured_repository: {:ok, {"owner", "repo"}},
      generation: 0,
      limit: Keyword.get(opts, :limit, 100)
    }
  end

  defp member(identity), do: %{identity: identity}

  defp identity(number, opts \\ []) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: Keyword.get(opts, :owner, "owner"),
      repository: Keyword.get(opts, :repository, "repo"),
      provider_id: Keyword.get(opts, :provider_id, "NODE-#{number}"),
      identifier: Integer.to_string(number),
      reason: nil
    }
  end

  defp merge(ticket_number, opts \\ []) do
    number = Keyword.get(opts, :number, ticket_number)
    repository = Keyword.get(opts, :repository, "owner/repo")
    merged_at = Keyword.get(opts, :merged_at, ~U[2026-07-17 11:00:00Z])

    %RecentMerge{
      id: Keyword.get(opts, :id, "#{repository}##{number}"),
      repository: repository,
      number: number,
      title: "Merge #{number}",
      summary: "Summary #{number}",
      url: "https://github.com/#{repository}/pull/#{number}",
      head_ref: Keyword.get(opts, :head_ref, "aiur/#{ticket_number}-work"),
      head_sha: "head-#{number}",
      merge_commit_sha: "merge-#{number}",
      merged_at: merged_at,
      observation_source: :github_events,
      backfilled?: Keyword.get(opts, :backfilled?, true),
      live_observed?: Keyword.get(opts, :live_observed?, false),
      observed_run_id: Keyword.get(opts, :observed_run_id),
      first_observed_at: merged_at,
      last_observed_at: merged_at,
      content_hash: "hash-#{number}"
    }
  end
end
