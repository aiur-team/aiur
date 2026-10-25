defmodule AiurWeb.BuildOrderPresenter.ActivityTest do
  use AiurWeb.BuildOrderPresenterCase

  test "reports stale activity, missing activity, and unavailable sources independently" do
    stale = activity(identity(1), 90, :review) |> Map.put(:status, :stale)

    model =
      BuildOrderPresenter.present(
        snapshot([member(2), member(1)]),
        :unavailable,
        activity_snapshot([stale])
      )

    assert model.execution_health == :unavailable
    assert node(model, 1).activity.status == :stale
    assert node(model, 1).activity.progress.percent == 90
    # A stale row keeps the percent it last reported, tagged as last known so
    # no consumer can mistake it for a live reading; the stage stays unknown.
    assert node(model, 1).card.progress == 90
    assert node(model, 1).card.progress_freshness == :stale
    assert node(model, 1).card.progress_observed_at == @now
    assert node(model, 1).card.agent_stage == :unknown
    # Missing activity is a separate fact: no percent, no freshness, no time.
    assert node(model, 2).activity.status == :unknown
    assert node(model, 2).card.progress == :unknown
    assert node(model, 2).card.progress_freshness == :unknown
    assert node(model, 2).card.progress_observed_at == nil
    assert node(model, 1).execution.status == :unknown
    assert node(model, 1).health.execution == :unavailable
  end

  test "a fresh row with a fresh reading projects a fresh card percent" do
    model = BuildOrderPresenter.present(snapshot([member(1)]), status_snapshot(), activity_snapshot([activity(identity(1), 42, :work)]))

    assert node(model, 1).card.progress == 42
    assert node(model, 1).card.progress_freshness == :fresh
    assert node(model, 1).card.progress_observed_at == @now
  end

  test "field-level stale activity keeps the percent as last known and never projects a current-looking stage" do
    stale_fields =
      activity(identity(1), 90, :review)
      |> put_in([:progress, :freshness], :stale)
      |> put_in([:stage, :freshness], :stale)

    model =
      BuildOrderPresenter.present(
        snapshot([member(1)]),
        status_snapshot(),
        activity_snapshot([stale_fields])
      )

    assert node(model, 1).activity.status == :fresh
    assert node(model, 1).activity.progress.freshness == :stale
    assert node(model, 1).activity.stage.freshness == :stale
    assert node(model, 1).card.progress == 90
    assert node(model, 1).card.progress_freshness == :stale
    assert node(model, 1).card.progress_observed_at == @now
    assert node(model, 1).card.agent_stage == :unknown
  end
end
