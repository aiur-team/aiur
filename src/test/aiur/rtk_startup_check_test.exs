defmodule Aiur.RtkStartupCheckTest do
  use ExUnit.Case, async: true

  alias Aiur.RtkStartupCheck

  @rtk "/usr/bin/rtk"

  test "emits one actionable attention alert when the host hook rewrites gh" do
    test_pid = self()

    opts = [
      rtk_path: @rtk,
      runner: fn rtk, ["hook", "check", "gh pr view 1"] when rtk == @rtk -> {"rtk gh pr view 1\n", 0} end,
      emit: fn topic, alert_opts -> send(test_pid, {:alert, topic, alert_opts}) end
    ]

    assert :ok = RtkStartupCheck.run(opts)
    assert_received {:alert, "system.rtk.gh_rewrite", alert_opts}
    assert alert_opts[:needs_attention]
    assert alert_opts[:message] =~ ~s(exclude_commands = ["gh"])
  end

  test "does not alert when gh is excluded" do
    runner = fn rtk, ["hook", "check", "gh pr view 1"] when rtk == @rtk -> {"No rewrite for: gh pr view 1\n", 1} end

    assert :ok = RtkStartupCheck.run(rtk_path: @rtk, runner: runner, emit: fn _, _ -> flunk("unexpected alert") end)
    refute_received {:alert, _, _}
  end

  test "does not probe or alert when rtk is absent" do
    runner = fn _, _ -> flunk("unexpected rtk probe") end

    assert :ok = RtkStartupCheck.run(rtk_path: nil, runner: runner, emit: fn _, _ -> flunk("unexpected alert") end)
    refute_received {:alert, _, _}
  end
end
