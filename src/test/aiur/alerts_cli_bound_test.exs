defmodule Aiur.AlertsCLIBoundTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.{AgentControlCLI, AlertFeed}

  setup do
    root = Aiur.TestSupport.tmp_root!("alerts-cli-bound")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{ledger: Path.join(root, "alerts.ndjson")}
  end

  test "default view keeps every open attention item and caps only other rows", %{ledger: ledger} do
    open = Enum.map(1..150, &alert(&1, true))
    history = Enum.map(1001..1200, &alert(&1, false))
    resolved = [alert(2001, true), Map.put(alert(2001, false), "topic", "system.test.2001.resolved")]
    write_ledger(ledger, open ++ history ++ resolved)

    [notice | alerts] = run_alerts(ledger_path: ledger)
    assert notice["event"] == "alert_feed_truncated"
    assert notice["limit"] == 100
    assert notice["omitted_count"] == 101
    attention = Enum.filter(alerts, & &1["needs_attention"])
    assert Enum.map(attention, & &1["topic"]) == Enum.map(1..150, &"system.test.#{&1}")
    others = Enum.reject(alerts, & &1["needs_attention"])
    assert length(others) == 100
    assert hd(others)["topic"] == "system.test.1102"
    assert List.last(alerts)["topic"] == "system.test.2001.resolved"
  end

  test "--needs-attention never truncates and excludes resolved conditions", %{ledger: ledger} do
    records = Enum.map(1..151, &alert(&1, true))
    write_ledger(ledger, records ++ [Map.put(alert(151, false), "topic", "system.test.151.resolved")])

    alerts = run_alerts(ledger_path: ledger, needs_attention: true)
    assert length(alerts) == 150
    refute Enum.any?(alerts, &(&1["event"] == "alert_feed_truncated"))
  end

  test "limit and :all expose rows the default cut", %{ledger: ledger} do
    write_ledger(ledger, Enum.map(1..250, &alert(&1, false)))

    [notice | alerts] = run_alerts(ledger_path: ledger, limit: 5)
    assert notice["omitted_count"] == 245
    assert Enum.map(alerts, & &1["topic"]) == Enum.map(246..250, &"system.test.#{&1}")
    assert length(run_alerts(ledger_path: ledger, limit: :all)) == 250
  end

  test "feed reconstruction grows linearly within the bounded ledger", %{ledger: ledger} do
    small = reductions(ledger, 1_000)
    large = reductions(ledger, 4_000)
    assert large < small * 6
  end

  # Deliberate future guard: tail seeking already bounded total-history I/O before this fix.
  test "future regression guard: discarded history bytes do not increase feed work", %{ledger: ledger} do
    tail = Enum.map(1..100, &[Jason.encode!(alert(&1, true)), "\n"]) |> IO.iodata_to_binary()
    opts = [ledger_path: ledger, max_bytes: byte_size(tail) + 10]

    costs =
      for bytes <- [1_024 * 1_024, 16 * 1_024 * 1_024] do
        File.write!(ledger, [String.duplicate("x", bytes), "\n", tail])
        {:reductions, before} = Process.info(self(), :reductions)
        assert length(AlertFeed.list(opts)) == 100
        {:reductions, after_count} = Process.info(self(), :reductions)
        after_count - before
      end

    [small, large] = costs
    assert large < small * 2
  end

  defp write_ledger(ledger, records), do: File.write!(ledger, Enum.map(records, &[Jason.encode!(&1), "\n"]))

  defp run_alerts(opts), do: capture_io(fn -> AgentControlCLI.alerts(opts) end) |> decode_output()

  defp decode_output(output) do
    output |> String.split("\n", trim: true) |> Enum.filter(&String.starts_with?(&1, "{")) |> Enum.map(&Jason.decode!/1)
  end

  defp reductions(ledger, count) do
    records = Enum.map(1..count, &alert(&1, rem(&1, 2) == 0))
    File.write!(ledger, Enum.map(records, &[Jason.encode!(&1), "\n"]))
    {:reductions, before} = Process.info(self(), :reductions)
    assert length(AlertFeed.list(ledger_path: ledger)) == count
    {:reductions, after_count} = Process.info(self(), :reductions)
    after_count - before
  end

  defp alert(index, attention) do
    %{"event" => "alert", "timestamp" => "2026-10-09T00:00:00Z", "topic" => "system.test.#{index}", "needs_attention" => attention}
  end
end
