defmodule AiurWeb.ExecutorViewTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Conversation.Presenter
  alias AiurWeb.ExecutorView

  @now ~U[2026-01-01 12:00:00Z]

  defp age(minutes_ago), do: Presenter.age(DateTime.add(@now, -minutes_ago * 60, :second), @now)

  test "unknown state with no reading says unknown and that its age is unknown, never idle" do
    summary = ExecutorView.summary(%{state: :unknown, age: Presenter.age(nil, @now)})
    assert summary == "unknown · age unknown"
  end

  test "a stale reading carries its age" do
    assert ExecutorView.summary(%{state: :degraded, age: age(12)}) == "stale 12m"
    assert ExecutorView.summary(%{state: :unknown, age: age(150)}) == "unknown 2h"
    assert ExecutorView.summary(%{state: :idle, age: age(30)}) == "idle 30m"
  end

  test "fresh and binding states read as short labels" do
    assert ExecutorView.summary(%{state: :live, age: age(1)}) == "attached"
    assert ExecutorView.summary(%{state: :not_opted_in, age: Presenter.age(nil, @now)}) == "not attached"
    assert ExecutorView.summary(%{state: :awaiting_hook, age: Presenter.age(nil, @now)}) == "waiting for session"
  end
end
