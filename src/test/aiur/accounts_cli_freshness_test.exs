defmodule Aiur.AccountsCLIFreshnessTest do
  @moduledoc """
  How `aiur accounts` reports a Claude reading that has stopped moving (#5747):
  stale with its age and last probe error, cached while under the cutoff, and
  `last_error` on Claude rows only.
  """

  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Accounts.UsageReadings
  alias Aiur.AccountsCLI

  setup do
    UsageReadings.reset()
    home = Aiur.TestSupport.tmp_root!("aiur-accounts-freshness")
    File.mkdir_p!(home)
    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      UsageReadings.reset()
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      Aiur.TestCleanup.rm_rf!(home)
    end)

    %{home: home}
  end

  # #5747: the reading went 3.6 h stale while the probe kept failing, and
  # `aiur accounts` gave no reason. A failing account must read as stale, show
  # how old its last real observation is, and name the last probe error.
  test "accounts json reports a failing account as stale with its age and last error", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))
    last_good = DateTime.add(DateTime.utc_now(), -3_600, :second)

    output =
      capture_io(fn ->
        AccountsCLI.accounts(true, fn _names ->
          %{
            "default" => %{
              reading: nil,
              observed_at: DateTime.utc_now(),
              freshness: :unavailable,
              reason: :rate_limited,
              consecutive_failures: 3,
              last_observed_at: last_good
            }
          }
        end)
      end)

    [row] = Jason.decode!(output) |> Enum.filter(&(&1["name"] == "default" and &1["harness"] == "claude"))
    assert row["freshness"] == "stale"
    assert row["last_error"] == "rate_limited"
    assert row["observed_at"] == DateTime.to_iso8601(last_good)
    assert row["age_ms"] >= 3_600_000
    assert row["weekly_percent"] == nil
  end

  test "accounts json reports a successful reading within the max age as fresh with no error", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))

    output =
      capture_io(fn ->
        AccountsCLI.accounts(true, fn _names ->
          %{
            "default" => %{
              reading: %{windows: [%{window: "seven_day", used_percent: 41}, %{window: "five_hour", used_percent: 18}]},
              observed_at: DateTime.add(DateTime.utc_now(), -60, :second),
              freshness: :fresh,
              reason: nil,
              consecutive_failures: 0
            }
          }
        end)
      end)

    [row] = Jason.decode!(output) |> Enum.filter(&(&1["name"] == "default" and &1["harness"] == "claude"))
    assert row["freshness"] == "fresh"
    assert row["last_error"] == nil
    assert row["weekly_percent"] == 41
  end

  # Failing since boot: there is no age to show, but the row must still say
  # why there is no reading.
  test "accounts json names the last error for an account that has never been read", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))

    output =
      capture_io(fn ->
        AccountsCLI.accounts(true, fn _names ->
          %{"default" => %{reading: nil, observed_at: DateTime.utc_now(), freshness: :unavailable, reason: :unauthorized, consecutive_failures: 2, last_observed_at: nil}}
        end)
      end)

    [row] = Jason.decode!(output) |> Enum.filter(&(&1["name"] == "default" and &1["harness"] == "claude"))
    assert row["freshness"] == "unauthorized"
    assert row["last_error"] == "unauthorized"
    assert row["age_ms"] == nil
  end

  # A reading re-served from cache after a 429 is `cached`, not `stale`, while
  # it is under the cutoff, the same call the Models panel makes, and it
  # still names the refusal.
  test "accounts json reports a cached reading under the cutoff as cached with its error", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))

    output =
      capture_io(fn ->
        AccountsCLI.accounts(true, fn _names ->
          %{
            "default" => %{
              reading: %{windows: [%{window: "seven_day", used_percent: 41}]},
              observed_at: DateTime.add(DateTime.utc_now(), -600, :second),
              freshness: :cached,
              reason: :rate_limited,
              consecutive_failures: 1
            }
          }
        end)
      end)

    [row] = Jason.decode!(output) |> Enum.filter(&(&1["name"] == "default" and &1["harness"] == "claude"))
    assert row["freshness"] == "cached"
    assert row["last_error"] == "rate_limited"
  end

  # `last_error` is a Claude probe field; other harnesses' rows keep their
  # existing shape so their pinned output does not change.
  test "accounts json leaves last_error off non-Claude rows", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))

    output = capture_io(fn -> AccountsCLI.accounts(true, fn _names -> %{} end) end)

    rows = Jason.decode!(output)
    refute Enum.any?(rows, &(&1["harness"] != "claude" and Map.has_key?(&1, "last_error")))
  end
end
