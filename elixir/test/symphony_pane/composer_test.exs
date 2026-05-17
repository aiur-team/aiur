defmodule SymphonyPane.ComposerTest do
  use ExUnit.Case, async: true

  alias SymphonyPane.Composer

  test "new/0 returns an empty state" do
    assert %{buffer: "", cursor: 0, history: []} = Composer.new()
  end

  test "append/2 returns state unchanged in the scaffold" do
    state = Composer.new()
    assert Composer.append(state, "a") == state
  end

  test "submit/2 returns a tuple shaped like {state, {:submit, payload}}" do
    state = Composer.new()
    assert {%{buffer: _}, {:submit, %{msg_id: _, body: _}}} = Composer.submit(state, "MT-1")
  end
end
