defmodule Aiur.AccountsCLIHeadroomTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AccountsCLI

  setup do
    home = Aiur.TestSupport.tmp_root!("aiur-accounts-headroom")
    File.mkdir_p!(home)
    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "accounts shows remaining percent for every backend, reading Codex from the usage ledger (#3960)", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))

    snapshot = fn _names ->
      %{"default" => %{reading: %{windows: [%{window: "seven_day", used_percent: 36}, %{window: "five_hour", used_percent: 50}]}, observed_at: DateTime.utc_now(), freshness: :fresh}}
    end

    ledger = fn
      "codex" -> %{windows: %{"short" => 12.0, "weekly" => 84.0}, source: "ledger", age_seconds: 90}
      _other -> nil
    end

    output = capture_io(fn -> assert :ok = AccountsCLI.accounts(true, nil, snapshot, ledger) end)
    rows = output |> String.split("\n", trim: true) |> hd() |> Jason.decode!()

    assert %{"remaining_percent" => 50} = Enum.find(rows, &(&1["harness"] == "claude"))
    assert %{"remaining_percent" => 16, "weekly_percent" => 84, "five_hour_percent" => 12, "freshness" => "ledger", "age_ms" => 90_000} = Enum.find(rows, &(&1["harness"] == "codex"))

    stale = capture_io(fn -> assert :ok = AccountsCLI.accounts(true, "codex", snapshot, fn "codex" -> %{stale: true, age_seconds: 7_200, source: "ledger"} end) end)
    assert [%{"freshness" => "stale_ledger", "age_ms" => 7_200_000, "remaining_percent" => nil, "weekly_percent" => nil}] = stale |> String.split("\n", trim: true) |> hd() |> Jason.decode!()

    text = capture_io(fn -> assert :ok = AccountsCLI.accounts(false, "codex", snapshot, fn "codex" -> nil end) end)
    assert text =~ "remaining_percent=nil"
    assert text =~ ~s(freshness="usage_not_polled")
  end
end
