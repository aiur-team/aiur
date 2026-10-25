defmodule AiurWeb.OperatorControlCenter.UnitsPresenterFreshnessTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.UnitsPresenter
  alias AiurWeb.StreamDeckGrid

  import AiurWeb.OperatorControlCenter.UnitsPresenterFixtures

  test "a stale fleet snapshot marks the catalog stale and names the age, not membership health" do
    alpha = identity("NODE-stale-fleet", "41")

    stale_payload =
      alpha
      |> payload()
      |> put_in([:fleet, :snapshot_freshness], %{status: :stale, reason: :snapshot_timeout, age_seconds: 342, observed_at: "2026-07-17T11:59:18Z"})

    catalog =
      UnitsPresenter.load(stale_payload,
        membership_fun: fn -> membership([member(alpha)]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.status == :stale
    assert catalog.message =~ "Fleet updates are pending"
    assert catalog.message =~ "5m 42s ago"
    refute catalog.message =~ "membership is healthy"
    assert [%{identity: ^alpha}] = catalog.snapshot.rows
  end

  # The Stream Deck projects a retained `:stale` snapshot unchanged, so the
  # Units catalog has to admit the same agents from the same snapshot. Before
  # this, any staleness dropped every status-sourced row and an operator with no
  # durable membership saw an empty Units page beside a full Stream Deck.
  test "a briefly stale fleet snapshot shows the same units the Stream Deck projects" do
    alpha = identity("NODE-parity-alpha", "41")
    beta = identity("NODE-parity-beta", "42")
    gamma = identity("NODE-parity-gamma", "43")

    fleet = %{
      running: [fleet_entry(alpha), fleet_entry(beta)],
      retrying: [],
      idle: [fleet_entry(gamma, work_state: :allocated, waiting_reason: :awaiting_dispatch)],
      snapshot_freshness: %{status: :stale, reason: :snapshot_timeout, age_seconds: 21, observed_at: "2026-07-17T11:59:39Z"}
    }

    catalog =
      UnitsPresenter.load(%{generated_at: "2026-07-17T12:00:00Z", provider_health: %{fleet: :ok, decisions: :ok}, fleet: fleet, decisions: []},
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )

    deck = StreamDeckGrid.project(fleet)

    assert deck.total == 3
    assert length(catalog.snapshot.rows) == deck.total
    assert Enum.map(catalog.snapshot.rows, & &1.identity) == [alpha, beta, gamma]
  end

  test "a fleet snapshot stale beyond the shared window stops standing in for membership" do
    alpha = identity("NODE-aged-alpha", "41")

    fleet = %{
      running: [fleet_entry(alpha)],
      retrying: [],
      idle: [],
      snapshot_freshness: %{status: :stale, reason: :snapshot_stalled, age_seconds: 900, observed_at: "2026-07-17T11:45:00Z"}
    }

    catalog =
      UnitsPresenter.load(%{generated_at: "2026-07-17T12:00:00Z", provider_health: %{fleet: :ok, decisions: :ok}, fleet: fleet, decisions: []},
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.snapshot.rows == []
    assert catalog.status == :stale
    assert catalog.message =~ "Fleet updates are pending"
  end

  # The window is exclusive at its boundary, and both surfaces agree there: the
  # rows stop being a floor at exactly the age the catalog starts calling itself
  # stale, so neither can be right while the other is wrong.
  test "the shared staleness window closes at the same age for rows and for catalog status" do
    alpha = identity("NODE-boundary", "41")

    catalog = fn age_seconds ->
      fleet = %{
        running: [fleet_entry(alpha)],
        retrying: [],
        idle: [],
        snapshot_freshness: %{status: :stale, reason: :snapshot_timeout, age_seconds: age_seconds, observed_at: "2026-07-17T11:55:00Z"}
      }

      UnitsPresenter.load(%{generated_at: "2026-07-17T12:00:00Z", provider_health: %{fleet: :ok, decisions: :ok}, fleet: fleet, decisions: []},
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )
    end

    assert length(catalog.(299).snapshot.rows) == 1
    assert catalog.(299).status == :ready
    assert catalog.(300).snapshot.rows == []
    assert catalog.(300).status == :stale
  end

  # An age-less `:stale` freshness cannot be judged against the window, so it
  # must not be admitted as a floor and must not read as a healthy catalog.
  test "a stale fleet view with no age is neither a row floor nor a ready catalog" do
    alpha = identity("NODE-ageless", "41")

    fleet = %{
      running: [fleet_entry(alpha)],
      retrying: [],
      idle: [],
      snapshot_freshness: %{status: :stale, reason: :snapshot_timeout, observed_at: "2026-07-17T11:55:00Z"}
    }

    catalog =
      UnitsPresenter.load(%{generated_at: "2026-07-17T12:00:00Z", provider_health: %{fleet: :ok, decisions: :ok}, fleet: fleet, decisions: []},
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.snapshot.rows == []
    assert catalog.status == :stale
  end

  test "a fleet snapshot marked stale while still young is not presented as stale" do
    alpha = identity("NODE-fresh-fleet", "41")

    young_payload =
      alpha
      |> payload()
      |> put_in([:fleet, :snapshot_freshness], %{status: :stale, reason: :snapshot_timeout, age_seconds: 18, observed_at: "2026-07-17T11:59:42Z"})

    catalog =
      UnitsPresenter.load(young_payload,
        membership_fun: fn -> membership([member(alpha)]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.status == :ready
    refute catalog.message
  end

  test "an unavailable fleet snapshot never reports a healthy membership as the reason" do
    alpha = identity("NODE-no-fleet", "41")

    unpublished_payload = %{
      generated_at: "2026-07-17T12:00:00Z",
      provider_health: %{fleet: :unavailable, decisions: :ok},
      fleet: %{error: %{code: "snapshot_unpublished", message: "No fleet snapshot published yet"}, running: [], retrying: [], idle: []},
      decisions: []
    }

    catalog =
      UnitsPresenter.load(unpublished_payload,
        membership_fun: fn -> membership([member(alpha)]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.status == :stale
    assert catalog.message == "The fleet is still counting units. Fleet data is unavailable."
    refute catalog.message =~ "healthy"
    assert [%{identity: ^alpha}] = catalog.snapshot.rows
  end

  test "a stale catalog with nothing retained does not claim to be showing a last-known-good catalog" do
    empty_fleet_payload = %{
      generated_at: "2026-07-17T12:00:00Z",
      provider_health: %{fleet: :unavailable, decisions: :ok},
      fleet: %{error: %{code: "snapshot_unpublished", message: "No fleet snapshot published yet"}, running: [], retrying: [], idle: []},
      decisions: []
    }

    catalog =
      UnitsPresenter.load(empty_fleet_payload,
        membership_fun: fn -> membership([]) end,
        activity_fun: fn -> %{entries: []} end
      )

    assert catalog.status == :stale
    assert catalog.snapshot.rows == []
    assert catalog.message == "No live units. Fleet data is unavailable."
    refute catalog.message =~ "The fleet is still counting units"
  end

  test "a reconciling membership is stale without claiming membership is healthy" do
    alpha = identity("NODE-reconciling", "41")

    reconciling = fn ->
      alpha |> List.wrap() |> Enum.map(&member/1) |> membership() |> Map.put(:freshness, %{status: :stale})
    end

    catalog = UnitsPresenter.load(payload(alpha), membership_fun: reconciling, activity_fun: fn -> %{entries: []} end)

    assert catalog.status == :stale
    assert catalog.message == "The fleet is still counting units."
    refute catalog.message =~ "healthy"
  end
end
