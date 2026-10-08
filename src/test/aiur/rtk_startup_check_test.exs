defmodule Aiur.RtkStartupCheckTest do
  use ExUnit.Case, async: true

  alias Aiur.RtkStartupCheck

  @rtk "/usr/bin/rtk"

  test "emits one informational alert when the host hook rewrites gh" do
    test_pid = self()

    opts = [
      rtk_path: @rtk,
      runner: fn rtk, ["hook", "check", "gh pr view 1"] when rtk == @rtk -> {"rtk gh pr view 1\n", 0} end,
      emit: fn topic, alert_opts -> send(test_pid, {:alert, topic, alert_opts}) end
    ]

    assert :ok = RtkStartupCheck.run(opts)
    assert_received {:alert, "system.rtk.gh_rewrite", alert_opts}
    refute alert_opts[:needs_attention]
    assert alert_opts[:severity] == "info"
    assert alert_opts[:message] =~ ~s(exclude_commands = ["gh"])
    assert alert_opts[:message] =~ "still reaches Aiur's GitHub quota guard through PATH"
  end

  test "logs when the alert cannot be recorded" do
    runner = fn _rtk, ["hook", "check", "gh pr view 1"] -> {"rtk gh pr view 1\n", 0} end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 RtkStartupCheck.run(
                   rtk_path: @rtk,
                   runner: runner,
                   emit: fn _, _ -> {:error, :ledger_unavailable} end
                 )
      end)

    assert log =~ "failed to record rtk host hook alert reason=:ledger_unavailable"
  end

  test "does not alert when gh is excluded" do
    test_pid = self()
    runner = fn rtk, ["hook", "check", "gh pr view 1"] when rtk == @rtk -> {"No rewrite for: gh pr view 1\n", 1} end

    assert :ok =
             RtkStartupCheck.run(
               rtk_path: @rtk,
               runner: runner,
               emit: fn topic, opts -> send(test_pid, {:alert, topic, opts}) end
             )

    refute_received {:alert, _, _}
  end

  test "does not probe or alert when rtk is absent" do
    test_pid = self()

    runner = fn _, _ ->
      send(test_pid, :probed)
      {"", 1}
    end

    assert :ok =
             RtkStartupCheck.run(
               rtk_path: nil,
               runner: runner,
               emit: fn topic, opts -> send(test_pid, {:alert, topic, opts}) end
             )

    refute_received :probed
    refute_received {:alert, _, _}
  end

  test "does not alert when rtk reports no hook despite printing a rewrite preview" do
    test_pid = self()
    runner = fn _rtk, ["hook", "check", "gh pr view 1"] -> {"[rtk] /!\\ No hook installed\nrtk gh pr view 1\n", 0} end

    assert :ok =
             RtkStartupCheck.run(
               rtk_path: @rtk,
               runner: runner,
               emit: fn topic, opts -> send(test_pid, {:alert, topic, opts}) end
             )

    refute_received {:alert, _, _}
  end
end
