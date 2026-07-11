defmodule Aiur.Opencode.Slot.SessionsTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.Slot.Sessions

  @unreachable_url "http://127.0.0.1:1"

  test "ensure/2 returns an error when serve is unreachable and does not raise" do
    result = Sessions.ensure("some-identifier", @unreachable_url)
    assert match?({:error, _}, result)
  end

  test "ensure_with_replay_span/3 returns {:writer_failed, {:error, _}} for unreachable serve" do
    result = Sessions.ensure_with_replay_span("some-identifier", @unreachable_url, 1)
    assert match?({:writer_failed, {:error, _}}, result)
  end
end
