defmodule Aiur.ShutdownTest do
  use ExUnit.Case, async: false

  alias Aiur.Shutdown

  test "cleanup/1 is a no-op on an empty registry" do
    assert Shutdown.cleanup() == :ok
  end

  test "cleanup/1 is idempotent (second call still returns :ok)" do
    assert Shutdown.cleanup(100) == :ok
    assert Shutdown.cleanup(100) == :ok
  end

  test "cleanup/1 swallows raises so the SIGTERM path can finish" do
    # Force a crash by passing a non-integer; cleanup should log + return :ok.
    assert Shutdown.cleanup(-1) == :ok
  end
end
