defmodule Aiur.GitHub.RequestOriginTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.RequestOrigin

  test "identifies Phoenix LiveView processes without relying on a caller name" do
    {:label, previous_label} = Process.info(self(), :label)
    Process.set_label({Phoenix.LiveView, AiurWeb.DashboardLive, "lv:test"})

    try do
      assert RequestOrigin.view_originated?()
      assert RequestOrigin.mark(%{caller: :issue_relationships}).view_originated?
      assert Task.async(fn -> RequestOrigin.view_originated?() end) |> Task.await()
      refute RequestOrigin.carry(false, fn -> RequestOrigin.view_originated?() end)
    after
      Process.set_label(previous_label)
    end
  end

  test "carries and restores a captured origin across an asynchronous boundary" do
    refute RequestOrigin.view_originated?()

    assert RequestOrigin.carry(true, fn -> RequestOrigin.view_originated?() end)
    refute RequestOrigin.view_originated?()
    refute RequestOrigin.mark(%{view_originated?: true}).view_originated?
  end
end
