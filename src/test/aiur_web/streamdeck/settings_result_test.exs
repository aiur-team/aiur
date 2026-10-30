defmodule AiurWeb.Streamdeck.SettingsResultTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Deck.{Nav, Settings}
  alias AiurWeb.Streamdeck.SettingsUpdates

  test "a successful saved view resets drill navigation and clears a previous failure" do
    nav = %Nav{view: :ticket, stack: [{:feature, "feature"}], drill_pages: [2], scroll: 3}
    nav = %{nav | settings: %{nav.settings | notice: "Not saved"}}
    saved = %{settings: Map.put(Settings.defaults(), "default_view", "epic")}
    applied = SettingsUpdates.apply_result(nav, %{"default_view" => "epic"}, {:ok, saved})
    assert applied.result == :ok
    assert applied.nav.view == :epic
    assert applied.nav.stack == []
    assert applied.nav.drill_pages == []
    assert applied.nav.scroll == 0
    assert applied.nav.settings.notice == "Saved"
    assert applied.toast == nil
  end

  test "a rejected save retains navigation and returns the same failure notice and toast" do
    nav = %Nav{view: :feature, stack: [{:feature, "feature"}], drill_pages: [1], scroll: 2}
    applied = SettingsUpdates.apply_result(nav, %{"default_view" => "epic"}, {:error, :eacces})
    assert applied.result == {:error, "not_saved"}
    assert %{applied.nav | settings: nav.settings} == nav
    assert applied.nav.settings.notice == "Not saved"
    assert applied.toast == "Not saved"
  end
end
