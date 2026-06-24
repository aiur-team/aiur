defmodule Aiur.IssueSummaryLogTest do
  use ExUnit.Case, async: false

  alias Aiur.IssueSummaryLog

  setup do
    original_log_file = Application.get_env(:aiur, :log_file)
    original_max = Application.get_env(:aiur, :issue_summary_log_max_lines)
    tmp = Path.join(System.tmp_dir!(), "aiur-summary-log-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "log"))
    Application.put_env(:aiur, :log_file, Path.join(tmp, "log/aiur.log"))

    on_exit(fn ->
      restore_app_env(:log_file, original_log_file)
      restore_app_env(:issue_summary_log_max_lines, original_max)
      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  test "writes dated bullets beside the raw per-issue log" do
    assert :ok =
             IssueSummaryLog.append_once("ISSUE/40", "Agent running", timestamp: ~U[2026-06-24 12:00:00Z])

    path = IssueSummaryLog.log_path("ISSUE/40")
    assert Path.basename(path) =~ ".ISSUE_40.summary.log"
    assert File.read!(path) == "2026-06-24 - Agent running\n"
  end

  test "skips exact duplicate bullets" do
    opts = [timestamp: ~U[2026-06-24 12:00:00Z]]

    assert :ok = IssueSummaryLog.append_once("40", "Status changed: paused", opts)
    assert :ok = IssueSummaryLog.append_once("40", "Status changed: paused", opts)

    assert File.read!(IssueSummaryLog.log_path("40")) == "2026-06-24 - Status changed: paused\n"
  end

  test "caps files to the newest configured lines" do
    Application.put_env(:aiur, :issue_summary_log_max_lines, 2)

    assert :ok = IssueSummaryLog.append_once("40", "one", timestamp: ~U[2026-06-24 12:00:00Z])
    assert :ok = IssueSummaryLog.append_once("40", "two", timestamp: ~U[2026-06-24 12:00:01Z])
    assert :ok = IssueSummaryLog.append_once("40", "three", timestamp: ~U[2026-06-24 12:00:02Z])

    assert File.read!(IssueSummaryLog.log_path("40")) ==
             "2026-06-24 - two\n2026-06-24 - three\n"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
