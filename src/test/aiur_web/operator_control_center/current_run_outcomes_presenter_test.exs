defmodule AiurWeb.OperatorControlCenter.CurrentRunOutcomesPresenterTest do
  use ExUnit.Case, async: true

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.CurrentRunOutcomesPresenter, as: Presenter

  describe "present/3 states" do
    test "healthy snapshot with qualified outcomes keeps a neutral heading" do
      view = Presenter.present(healthy_snapshot(outcomes: [outcome(number: 42)]))

      assert view.state == :healthy
      assert view.finished_this_run?
      assert view.heading == "Current-run outcomes"
      assert [%{number: 42}] = view.outcomes
    end

    test "healthy empty snapshot claims no outcomes only when complete" do
      view = Presenter.present(healthy_snapshot(outcomes: [], state: :healthy_empty))

      assert view.state == :healthy_empty
      assert view.finished_this_run?
      assert view.heading == "Current-run outcomes"
      assert view.outcomes == []
      assert Presenter.announcement(view) =~ "No repository merges have finished this run yet"
    end

    test "partial snapshot never claims Finished this run and never a confident empty" do
      view =
        Presenter.present(
          healthy_snapshot(
            outcomes: [outcome(number: 7)],
            state: :partial,
            health: %{status: :partial, reasons: [:reconciliation_incomplete]},
            freshness: %{status: :partial}
          )
        )

      assert view.state == :partial
      refute view.finished_this_run?
      assert view.heading == "Current-run outcomes"
      assert Presenter.announcement(view) =~ "Results may be incomplete"
    end

    test "stale membership/run window surfaces a partial, non-confident heading" do
      view =
        Presenter.present(
          healthy_snapshot(
            outcomes: [outcome(number: 7)],
            state: :stale,
            health: %{status: :partial, reasons: [:membership_stale]},
            freshness: %{status: :stale}
          )
        )

      assert view.state == :stale
      refute view.finished_this_run?
    end

    test "merge source unavailable renders the named unavailable state" do
      view =
        Presenter.present(unavailable_snapshot(reasons: [:merge_source_unavailable]))

      assert view.state == :unavailable
      refute view.finished_this_run?
      assert view.outcomes == []
      assert Presenter.announcement(view) =~ "unavailable"
      assert Presenter.announcement(view) =~ "merge source unavailable"
    end

    test "run-identity transition renders the distinct new-run state" do
      for reason <- [:invalid_run_window, :run_membership_mismatch] do
        view = Presenter.present(unavailable_snapshot(reasons: [reason]))

        assert view.state == :new_run, "expected new_run for #{reason}"
        refute view.finished_this_run?
        assert Presenter.announcement(view) =~ "new run is starting"
      end
    end

    test "truncated snapshot exposes the truncation flag and limit" do
      view =
        Presenter.present(
          healthy_snapshot(
            outcomes: [outcome(number: 1)],
            truncated?: true,
            limit: 100,
            counts: %{input: 250, invalid: 0, deduplicated: 250, qualified: 250, returned: 100}
          )
        )

      assert view.truncated?
      assert view.limit == 100
      assert Presenter.announcement(view) =~ "Showing 100 of 250 qualified outcomes"
    end

    test "a degraded state never surfaces cards even from a malformed snapshot" do
      for {reasons, expected} <- [{[:merge_source_unavailable], :unavailable}, {[:invalid_run_window], :new_run}] do
        malformed = %{unavailable_snapshot(reasons: reasons) | outcomes: [outcome(number: 99)]}
        view = Presenter.present(malformed)

        assert view.state == expected
        assert view.outcomes == []
      end
    end

    test "nil source presents the loading view" do
      view = Presenter.present(nil)

      assert view.state == :loading
      refute view.finished_this_run?
      assert view.outcomes == []
      assert Presenter.announcement(view) == "Loading current-run outcomes."
    end
  end

  describe "label gate" do
    test "requires a canonical current-run membership generation" do
      view =
        Presenter.present(healthy_snapshot(outcomes: [], state: :healthy_empty, membership_generation: nil))

      assert view.state == :healthy_empty
      refute view.finished_this_run?
      assert view.heading == "Current-run outcomes"
    end

    test "requires a run id" do
      view = Presenter.present(healthy_snapshot(outcomes: [], state: :healthy_empty, run_id: nil))

      refute view.finished_this_run?
    end
  end

  describe "outcome presentation" do
    test "preserves the exact snapshot order and never re-sorts by observation" do
      outcomes = [
        outcome(number: 3, id: "c", merged_at: ~U[2026-07-17 09:00:00Z]),
        outcome(number: 1, id: "a", merged_at: ~U[2026-07-17 12:00:00Z]),
        outcome(number: 2, id: "b", merged_at: ~U[2026-07-17 10:00:00Z])
      ]

      view = Presenter.present(healthy_snapshot(outcomes: outcomes))

      assert Enum.map(view.outcomes, & &1.number) == [3, 1, 2]
    end

    test "renders canonical ticket identity, keyed dom id, and drops unsafe links" do
      identity = %TrackerIdentity{status: :joinable, kind: :github, owner: "its-everdred", repository: "aiur", identifier: "1138"}

      [row] =
        Presenter.present(healthy_snapshot(outcomes: [outcome(number: 5, id: "merge-5", identity: identity, url: "javascript:alert(1)")])).outcomes

      assert row.ticket_identity == "its-everdred/aiur #1138"
      assert row.id == "current-run-outcome-merge-5"
      assert row.url == nil
    end

    test "keeps trusted https PR links" do
      [row] =
        Presenter.present(healthy_snapshot(outcomes: [outcome(number: 5, url: "https://github.com/its-everdred/aiur/pull/5")])).outcomes

      assert row.url == "https://github.com/its-everdred/aiur/pull/5"
    end

    test "observed_run_id is shown as provenance only for live-observed outcomes and never selects a card" do
      observed = outcome(number: 9, live_observed?: true, observed_run_id: "run-observer-1234567890")
      backfilled = outcome(number: 8, live_observed?: false, backfilled?: true, observed_run_id: "run-observer-x")

      view = Presenter.present(healthy_snapshot(outcomes: [observed, backfilled]))

      assert [%{observed_run_id: shown}, %{observed_run_id: nil, backfilled?: true}] = view.outcomes
      assert shown == "run-observer"
      # Both outcomes render regardless of observed_run_id; it never filters.
      assert length(view.outcomes) == 2
    end

    test "bounds long title and summary text" do
      long = String.duplicate("x", 500)

      [row] =
        Presenter.present(healthy_snapshot(outcomes: [outcome(number: 1, title: long, summary: long)])).outcomes

      assert String.length(row.title) <= 200
      assert String.length(row.summary) <= 280
    end
  end

  describe "reconcile/2 retention" do
    test "adopts an available incoming snapshot" do
      current = healthy_snapshot(outcomes: [outcome(number: 1)])
      incoming = healthy_snapshot(outcomes: [outcome(number: 2)])

      assert {^incoming, false} = Presenter.reconcile(current, incoming)
    end

    test "retains a healthy same-run snapshot across an unavailable update" do
      current = healthy_snapshot(outcomes: [outcome(number: 1)], run_id: "run-1")
      incoming = unavailable_snapshot(reasons: [:merge_source_unavailable], run_id: "run-1")

      assert {^current, true} = Presenter.reconcile(current, incoming)

      view = Presenter.present(current, true, incoming)
      assert view.state == :stale
      assert [%{number: 1}] = view.outcomes
      assert view.health.label == "Unavailable"
    end

    test "shows a new-run unavailable snapshot instead of the prior run" do
      current = healthy_snapshot(outcomes: [outcome(number: 1)], run_id: "run-1")
      incoming = unavailable_snapshot(reasons: [:invalid_run_window], run_id: "run-2")

      assert {^incoming, false} = Presenter.reconcile(current, incoming)
    end

    test "a changed run generation is adopted, dropping prior-run cards" do
      current = healthy_snapshot(outcomes: [outcome(number: 1)], run_id: "run-1")
      incoming = healthy_snapshot(outcomes: [outcome(number: 9)], run_id: "run-2")

      {source, false} = Presenter.reconcile(current, incoming)
      view = Presenter.present(source)

      assert Enum.map(view.outcomes, & &1.number) == [9]
    end
  end

  # --- fixtures ------------------------------------------------------------

  defp healthy_snapshot(opts) do
    outcomes = Keyword.get(opts, :outcomes, [])

    %{
      version: 1,
      generation: Keyword.get(opts, :generation, 3),
      state: Keyword.get(opts, :state, :healthy),
      run: %{
        id: Keyword.get(opts, :run_id, "run-1"),
        started_at: ~U[2026-07-17 10:00:00Z],
        observed_at: ~U[2026-07-17 12:00:00Z]
      },
      repository: "its-everdred/aiur",
      membership: %{generation: Keyword.get(opts, :membership_generation, 4), signature: "sig"},
      outcomes: outcomes,
      counts: Keyword.get(opts, :counts, %{input: length(outcomes), invalid: 0, deduplicated: length(outcomes), qualified: length(outcomes), returned: length(outcomes)}),
      exclusions: %{},
      limit: Keyword.get(opts, :limit, 100),
      truncated?: Keyword.get(opts, :truncated?, false),
      health: Keyword.get(opts, :health, %{status: :healthy, reasons: []}),
      freshness: Keyword.get(opts, :freshness, %{status: :fresh}),
      sources: %{}
    }
  end

  defp unavailable_snapshot(opts) do
    healthy_snapshot(opts)
    |> Map.put(:state, :unavailable)
    |> Map.put(:outcomes, [])
    |> Map.put(:health, %{status: :unavailable, reasons: Keyword.get(opts, :reasons, [:merge_source_unavailable])})
    |> Map.put(:freshness, %{status: :unavailable})
    |> Map.put(:counts, %{input: 0, invalid: 0, deduplicated: 0, qualified: 0, returned: 0})
  end

  defp outcome(opts) do
    identity =
      Keyword.get(opts, :identity, %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        identifier: "#{Keyword.get(opts, :number, 1)}"
      })

    %{
      id: Keyword.get(opts, :id, "merge-#{Keyword.get(opts, :number, 1)}"),
      repository: "its-everdred/aiur",
      number: Keyword.get(opts, :number, 1),
      title: Keyword.get(opts, :title, "Ship the thing"),
      summary: Keyword.get(opts, :summary, "A short safe summary."),
      url: Keyword.get(opts, :url, "https://github.com/its-everdred/aiur/pull/#{Keyword.get(opts, :number, 1)}"),
      head_ref: "aiur/1138-slug",
      head_sha: "abc123",
      merge_commit_sha: "def456",
      merged_at: Keyword.get(opts, :merged_at, ~U[2026-07-17 11:00:00Z]),
      member: %{identity: identity, identifier: identity.identifier},
      association: %{version: 1, basis: :configured_repository_branch_locator_unique_membership_run_window},
      run: %{id: "run-1", started_at: ~U[2026-07-17 10:00:00Z], observed_at: ~U[2026-07-17 12:00:00Z], membership_generation: 4},
      observation: %{
        source: :recent_merge_store,
        backfilled?: Keyword.get(opts, :backfilled?, false),
        live_observed?: Keyword.get(opts, :live_observed?, false),
        observed_run_id: Keyword.get(opts, :observed_run_id, nil),
        first_observed_at: ~U[2026-07-17 11:00:00Z],
        last_observed_at: ~U[2026-07-17 11:05:00Z]
      }
    }
  end
end
