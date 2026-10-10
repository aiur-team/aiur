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

  test "RPC bounds output after resolving and filtering retained history", %{ledger: ledger} do
    records = Enum.map(1..200, &alert(&1, false))
    records = records ++ [alert(201, true), Map.put(alert(201, false), "topic", "system.test.201.resolved")]
    File.write!(ledger, Enum.map(records, &[Jason.encode!(&1), "\n"]))

    output = capture_io(fn -> AgentControlCLI.alerts(ledger_path: ledger) end)
    [notice | alerts] = decode_output(output)
    assert notice["event"] == "alert_feed_truncated"
    assert notice["limit"] == 100
    assert notice["matching_count"] == 201
    assert notice["message"] =~ "older matches omitted"
    assert length(alerts) == 100
    assert hd(alerts)["topic"] == "system.test.102"
    assert List.last(alerts)["topic"] == "system.test.201.resolved"
    refute capture_io(fn -> AgentControlCLI.alerts(ledger_path: ledger, needs_attention: true) end) =~ "system.test.201"
  end

  test "attention RPC caps matching results and excludes resolved conditions", %{ledger: ledger} do
    records = Enum.map(1..151, &alert(&1, true))
    records = records ++ [Map.put(alert(151, false), "topic", "system.test.151.resolved")]
    File.write!(ledger, Enum.map(records, &[Jason.encode!(&1), "\n"]))

    output = capture_io(fn -> AgentControlCLI.alerts(ledger_path: ledger, needs_attention: true) end)
    [notice | alerts] = decode_output(output)
    assert notice["matching_count"] == 150
    assert length(alerts) == 100
    assert hd(alerts)["topic"] == "system.test.51"
    assert List.last(alerts)["topic"] == "system.test.150"
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
