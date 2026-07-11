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

  test "spawn propagates a split failure when tmux is unavailable" do
    assert {:error, :no_tmux} = AttachPane.spawn(3, "http://127.0.0.1:1", "%missing")
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

  # --- dump_pipe_tail/1 ---

  test "dump_pipe_tail returns :ok for nonexistent path" do
    # pipe_pane_path(9999) → "/tmp/aiur-debug/slot-9999-attach.log" (does not exist)
    assert :ok = AttachPane.dump_pipe_tail(9999)
  end

  test "dump_pipe_tail reads an existing debug pipe" do
    slot_index = 9998
    path = AttachPane.pipe_pane_path(slot_index)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "first line\nsecond line\n")
    on_exit(fn -> File.rm(path) end)

    assert :ok = AttachPane.dump_pipe_tail(slot_index)
  end

  # --- maybe_start_pipe_pane/2 ---

  test "maybe_start_pipe_pane returns :ok when debug mode is off (binary pane)" do
    System.delete_env("AIUR_DEBUG")
    assert :ok = AttachPane.maybe_start_pipe_pane(3, "%99")
  end

  test "maybe_start_pipe_pane returns :ok for non-binary pane_id" do
    assert :ok = AttachPane.maybe_start_pipe_pane(3, nil)
  end

  test "maybe_start_pipe_pane returns :ok when debug mode is on (binary pane, no tmux)" do
    System.put_env("AIUR_DEBUG", "1")
    # Tmux not running; command returns {:error, :no_tmux} but result is discarded
    assert :ok = AttachPane.maybe_start_pipe_pane(5, "%77")
  end

  # --- probe/1 ---

  test "probe returns {:missing, _} when Tmux is not running" do
    # Tmux.command catches :noproc and returns {:error, :no_tmux}
    assert {:missing, _} = AttachPane.probe("%nonexistent")
  end

  # --- kill/2 ---

  test "kill with default opts returns :ok without tmux or reaper" do
    # ProcessReaper.unregister and Tmux.command both handle missing processes gracefully
    assert :ok = AttachPane.kill("%fake-pane")
  end

  test "kill with unregister: false skips reaper call and returns :ok" do
    assert :ok = AttachPane.kill("%fake-pane", unregister: false)
  end

  # --- capture_pane_dump/1 ---

  test "capture_pane_dump returns 'capture_failed' when Tmux is not running" do
    assert "capture_failed" = AttachPane.capture_pane_dump("%nonexistent")
  end

  # --- reflow_hidden_window/1 ---

  test "reflow_hidden_window returns :ok when Tmux is not running" do
    assert :ok = AttachPane.reflow_hidden_window("%1")
  end

  # --- hidden_window_target/0 ---

  test "hidden_window_target returns :hidden_window_disabled when HiddenWindow is not running" do
    # HiddenWindow.status() returns :disabled when the process is not registered
    assert {:error, :hidden_window_disabled} = AttachPane.hidden_window_target()
  end

  test "respawn maps unavailable hidden window to respawn failure" do
    assert {:error, :respawn_failed} =
             AttachPane.respawn_with_session(%{slot_index: 3, pane_id: nil}, "session-1", "attach")
  end

  test "respawn retires an existing pane before mapping hidden-window failure" do
    assert {:error, :respawn_failed} =
             AttachPane.respawn_with_session(%{slot_index: 3, pane_id: "%missing"}, "session-1", "attach")
  end
end
