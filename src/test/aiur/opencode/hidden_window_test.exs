defmodule Aiur.Opencode.HiddenWindowTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.HiddenWindow

  describe "window_name/0" do
    test "returns the configured window name" do
      assert is_binary(HiddenWindow.window_name())
      assert HiddenWindow.window_name() != ""
    end
  end

  describe "keep_alive_command/0" do
    test "is portable across BSD (macOS) and GNU sleep" do
      cmd = HiddenWindow.keep_alive_command()

      # `sleep infinity` is GNU-only; BSD/macOS sleep rejects it, so the
      # keep-alive pane would exit immediately and tmux would close it,
      # dropping the hidden window's pane mid-boot.
      refute cmd =~ "infinity"
      assert cmd =~ ~r/^sleep \d+$/
    end
  end

  describe "status/0 + ensure/1 without a running process" do
    test "status/0 returns :disabled when no GenServer is started" do
      # No PrewarmSupervisor in this test, so the module is not registered.
      refute Process.whereis(HiddenWindow)
      assert HiddenWindow.status() == :disabled
    end

    test "ensure/1 returns {:error, :not_started} when no GenServer is started" do
      refute Process.whereis(HiddenWindow)
      assert HiddenWindow.ensure(100) == {:error, :not_started}
    end
  end
end
