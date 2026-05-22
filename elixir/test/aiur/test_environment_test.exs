defmodule Aiur.TestEnvironmentTest do
  use ExUnit.Case, async: false

  @sanitized_env_vars [
    "TMUX",
    "TMUX_PANE",
    "ERL_AFLAGS",
    "AIUR_NODE",
    "AIUR_ERLANG_COOKIE",
    "AIUR_TMUX_CONF",
    "AIUR_TMUX_SESSION",
    "AIUR_TMUX_SOCKET",
    "XDG_RUNTIME_DIR"
  ]

  test "test setup removes env inherited from aiur shells" do
    assert Enum.all?(@sanitized_env_vars, &(System.get_env(&1) == nil))
  end

  test "test setup provides a writable HOME" do
    home = System.fetch_env!("HOME")
    probe = Path.join(home, "write-check")

    File.write!(probe, "ok")

    assert File.read!(probe) == "ok"
  end
end
