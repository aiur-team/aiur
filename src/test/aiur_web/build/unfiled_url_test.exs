defmodule AiurWeb.Build.UnfiledURLTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Build.URLState

  test "pack links survive URL parsing and canonical query serialization" do
    state = URLState.parse(%{"ticket" => "pack:demo/T-1"})
    assert state.ticket == "pack:demo/T-1"
    assert URI.decode_query(URLState.to_query(state))["ticket"] == "pack:demo/T-1"
  end

  test "future regression guard: invalid pack links are rejected" do
    for id <- ["pack:../x", "pack:demo", "pack:demo/", "pack:demo/A/B"] do
      assert URLState.parse(%{"ticket" => id}).ticket == nil
    end
  end
end
