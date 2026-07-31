defmodule AiurWeb.OperatorControlCenter.CurrentRunOutcomesTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.CurrentRunOutcomes
  alias AiurWeb.OperatorControlCenter.CurrentRunOutcomesPresenter, as: Presenter

  test "healthy outcomes render keyed cards and safe links" do
    identity = %TrackerIdentity{status: :joinable, kind: :github, owner: "its-everdred", repository: "aiur", identifier: "1138"}
    view = present([outcome(number: 42, id: "merge-42", identity: identity)])

    html = render(view)

    refute html =~ "Finished this run"
    assert html =~ ~s(id="current-run-outcome-merge-42")
    assert html =~ "PR #42"
    assert html =~ "aiur-team/aiur #1138"
    assert html =~ ~s(href="https://github.com/aiur-team/aiur/pull/42")
    assert html =~ ~s(rel="noopener noreferrer")
    refute html =~ "Open analytics report"
    refute html =~ "aiur.team"
    # Trimmed to a short label; the legalese association disclaimer is gone.
    refute html =~ "Repository merges from this run."
    refute html =~ "authored by"
    refute html =~ "proof of authorship"
  end

  test "healthy-empty renders a confident no-outcomes claim without a visible heading" do
    html = render(present([], state: :healthy_empty))

    refute html =~ "Finished this run"
    assert html =~ "No repository merges have finished this run yet"
  end

  test "partial state uses a neutral heading and an incomplete caveat, never a confident empty" do
    html =
      render(present([], state: :partial, health: %{status: :partial, reasons: [:reconciliation_incomplete]}, freshness: %{status: :partial}))

    assert html =~ "Current-run outcomes"
    refute html =~ "Finished this run"
    assert html =~ "may be incomplete"
    refute html =~ "No repository merges have finished this run yet"
  end

  test "unavailable state names the reason and renders no cards" do
    html = render(present_unavailable([:merge_source_unavailable]))

    assert html =~ "Current-run outcomes unavailable"
    assert html =~ "merge source unavailable"
    refute html =~ "outcome-card"
  end

  test "new-run state explains previous outcomes are cleared" do
    html = render(present_unavailable([:invalid_run_window]))

    assert html =~ "A new run is starting"
    refute html =~ "outcome-card"
  end

  test "stale retention shows retained cards with a stale banner" do
    current = snapshot([outcome(number: 1)], run_id: "run-1")
    incoming = unavailable_snapshot([:merge_source_unavailable], run_id: "run-1")
    {source, true} = Presenter.reconcile(current, incoming)
    view = Presenter.present(source, true, incoming)

    html =
      render_component(&CurrentRunOutcomes.current_run_outcomes/1,
        view: view,
        announcement: Presenter.announcement(view)
      )

    assert html =~ "Stale outcomes"
    assert html =~ "PR #1"
  end

  # --- helpers -------------------------------------------------------------

  defp render(view) do
    render_component(&CurrentRunOutcomes.current_run_outcomes/1,
      view: view,
      announcement: Presenter.announcement(view)
    )
  end

  defp present(outcomes, opts \\ []), do: Presenter.present(snapshot(outcomes, opts))
  defp present_unavailable(reasons), do: Presenter.present(unavailable_snapshot(reasons, []))

  defp snapshot(outcomes, opts) do
    %{
      version: 1,
      generation: 3,
      state: Keyword.get(opts, :state, if(outcomes == [], do: :healthy_empty, else: :healthy)),
      run: %{id: Keyword.get(opts, :run_id, "run-1"), started_at: ~U[2026-07-17 10:00:00Z], observed_at: ~U[2026-07-17 12:00:00Z]},
      repository: "aiur-team/aiur",
      membership: %{generation: 4, signature: "sig"},
      outcomes: outcomes,
      counts: %{input: length(outcomes), invalid: 0, deduplicated: length(outcomes), qualified: length(outcomes), returned: length(outcomes)},
      exclusions: %{},
      limit: 100,
      truncated?: false,
      health: Keyword.get(opts, :health, %{status: :healthy, reasons: []}),
      freshness: Keyword.get(opts, :freshness, %{status: :fresh}),
      sources: %{}
    }
  end

  defp unavailable_snapshot(reasons, opts) do
    snapshot([], opts)
    |> Map.put(:state, :unavailable)
    |> Map.put(:health, %{status: :unavailable, reasons: reasons})
    |> Map.put(:freshness, %{status: :unavailable})
  end

  defp outcome(opts) do
    number = Keyword.get(opts, :number, 1)

    identity =
      Keyword.get(opts, :identity, %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        identifier: "#{number}"
      })

    %{
      id: Keyword.get(opts, :id, "merge-#{number}"),
      repository: "aiur-team/aiur",
      number: number,
      title: "Ship the thing",
      summary: "A short safe summary.",
      url: "https://github.com/aiur-team/aiur/pull/#{number}",
      head_ref: "aiur/1138-slug",
      head_sha: "abc123",
      merge_commit_sha: "def456",
      merged_at: ~U[2026-07-17 11:00:00Z],
      member: %{identity: identity, identifier: identity.identifier},
      association: %{version: 1, basis: :configured_repository_branch_locator_unique_membership_run_window},
      run: %{id: "run-1", started_at: ~U[2026-07-17 10:00:00Z], observed_at: ~U[2026-07-17 12:00:00Z], membership_generation: 4},
      observation: %{source: :recent_merge_store, backfilled?: false, live_observed?: false, observed_run_id: nil, first_observed_at: nil, last_observed_at: nil}
    }
  end
end
