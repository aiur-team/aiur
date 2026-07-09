defmodule Aiur.Opencode.Slot.AttachPaneTest do
  use ExUnit.Case, async: false

  alias Aiur.Opencode.Slot.AttachPane

  setup do
    on_exit(fn ->
      System.delete_env("AIUR_DEBUG")
    end)
  end

  # --- terminate_pane_command/1 ---

  test "terminate_pane_command returns kill command when pane_id is binary" do
    assert "kill-pane -t %42" = AttachPane.terminate_pane_command(%{pane_id: "%42"})
  end

  test "terminate_pane_command returns nil when pane_id is nil" do
    assert nil == AttachPane.terminate_pane_command(%{pane_id: nil})
  end

  test "terminate_pane_command returns nil when state has no pane" do
    assert nil == AttachPane.terminate_pane_command(%{})
  end

  # --- pipe_pane_path/1 ---

  test "pipe_pane_path returns expected path" do
    assert "/tmp/aiur-debug/slot-3-attach.log" = AttachPane.pipe_pane_path(3)
  end

  # --- debug_mode?/0 ---

  test "debug_mode? returns true for AIUR_DEBUG=1" do
    System.put_env("AIUR_DEBUG", "1")
    assert AttachPane.debug_mode?()
  end

  test "debug_mode? returns true for AIUR_DEBUG=true" do
    System.put_env("AIUR_DEBUG", "true")
    assert AttachPane.debug_mode?()
  end

  test "debug_mode? returns true for AIUR_DEBUG=yes" do
    System.put_env("AIUR_DEBUG", "yes")
    assert AttachPane.debug_mode?()
  end

  test "debug_mode? returns false for AIUR_DEBUG=0" do
    System.put_env("AIUR_DEBUG", "0")
    refute AttachPane.debug_mode?()
  end

  test "debug_mode? returns false when AIUR_DEBUG unset" do
    System.delete_env("AIUR_DEBUG")
    refute AttachPane.debug_mode?()
  end
end
