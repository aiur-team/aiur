defmodule AiurWeb.Streamdeck.Deck.MeterProvidersTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Deck.{MeterPage, Meters, Nav}

  test "API credits never become provider account keys" do
    usage = %{"claude" => %{"summary_label" => "personal"}, "apis" => %{"remaining" => 9}}
    assert Meters.providers(usage) == %{"claude" => %{"summary_label" => "personal"}}
    assert Meters.providers(%{}) == %{}
    sections = MeterPage.sections(%{fleet: %{keys: []}, meter_usage: usage}, %Nav{view: :fleet})
    assert [%{id: "claude", kind: :meter_detail}] = Enum.reject(sections.fleet, &is_nil/1)
  end
end
