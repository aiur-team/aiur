defmodule AiurWeb.Conversation.PresenterTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias AiurWeb.Conversation.{Components, Presenter}

  test "each conversation state follows the latest session, entry age and writer flag" do
    now = DateTime.utc_now()
    page = %{head_pos: 1, entries: [%{observed_at: now}], sessions: [%{end_reason: nil, ended_at: nil}]}
    assert Presenter.state(:loading) == :loading
    assert Presenter.state({:error, :not_found}) == :not_found
    assert Presenter.state({:error, :unavailable}) == :unavailable
    assert Presenter.state(%{page | head_pos: 0}) == :known_empty
    assert Presenter.state(page, now: now) == :live
    assert Presenter.state(page, now: DateTime.add(now, 601)) == :idle
    assert Presenter.state(page, degraded: true) == :degraded

    for reason <- ["stopped", "turn_limit", "superseded", "completed"] do
      assert Presenter.state(%{page | sessions: [%{end_reason: reason}]}) == :ended
    end

    assert Presenter.state(%{page | sessions: [%{end_reason: "daemon_restart_unknown"}]}) == :restart_unknown
    assert Presenter.state(%{page | sessions: [%{end_reason: "future_reason"}]}) == :unknown
    assert Presenter.state(%{page | sessions: []}) == :unknown
  end

  test "age preserves unknown timestamps instead of inventing a zero" do
    now = DateTime.utc_now()
    assert %{age_ms: nil, observed_at: nil, freshness: :unknown, text: "age unknown"} = Presenter.age(nil, now)
    assert %{age_ms: nil, text: "age unknown"} = Presenter.age("invalid", now)
    old = DateTime.add(now, -601)
    assert %{age_ms: 601_000, observed_at: ^old, freshness: :stale, text: "601 seconds ago"} = Presenter.age(old, now)
    assert %{age_ms: 0, freshness: :fresh} = Presenter.age(now, now)
  end

  test "idle and unknown ages are rendered as observed, without a plausible default" do
    now = DateTime.utc_now()
    age = Presenter.age(DateTime.add(now, -601), now)
    html = render_component(&Components.status/1, state: :idle, age: age)
    assert html =~ "601 seconds ago"
    assert html =~ DateTime.to_iso8601(age.observed_at)
    assert html =~ "stale"
    unknown = render_component(&Components.status/1, state: :idle, age: Presenter.age(nil, now))
    assert unknown =~ "age unknown"
    refute unknown =~ "0 seconds ago"
  end
end
