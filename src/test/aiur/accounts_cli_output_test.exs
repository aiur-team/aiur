defmodule Aiur.AccountsCLIOutputTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Accounts
  alias Aiur.AccountsCLI

  setup do
    home = Aiur.TestSupport.tmp_root!("aiur-accounts-cli-output")
    File.mkdir_p!(Path.join(home, ".aiur"))
    previous = System.get_env("HOME")
    System.put_env("HOME", home)
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com","organizationName":"Example","subscriptionType":"max"}}))
    File.write!(Path.join(home, ".aiur/.env"), "DEEPSEEK_API_KEY__WORK=sk-fixture\n")
    :ok = Accounts.register("deepseek", "work")

    on_exit(fn ->
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      Aiur.TestCleanup.rm_rf!(home)
    end)

    :ok
  end

  defp snapshot(_names), do: %{"default" => %{freshness: :unavailable, reason: :no_oauth_token}}
  defp ledger("codex"), do: %{stale: true, age_seconds: 120, source: "ledger"}
  defp ledger(_harness), do: nil

  defp output(json, harness), do: capture_io(fn -> :ok = AccountsCLI.accounts(json, harness, &snapshot/1, &ledger/1) end)

  # `aiur accounts` output is read by operators and scripts. The HTTP snapshot
  # reuses its row builder, and that reuse must not change it: text is pinned
  # byte for byte. JSON is pinned by value, because the key order of an
  # atom-keyed map follows the VM atom table and already varies between builds.
  test "text output is unchanged" do
    assert output(false, "claude") ==
             ~s(name="default"  harness="claude"  email="dev@example.com"  org="Example"  seat_tier="max"  remaining_percent=nil  weekly_percent=nil  five_hour_percent=nil  freshness="no_oauth_token"  age_ms=nil\n)

    assert output(false, "codex") ==
             ~s(name="default"  harness="codex"  email=nil  org=nil  seat_tier=nil  remaining_percent=nil  weekly_percent=nil  five_hour_percent=nil  freshness="stale_ledger"  age_ms=120000\n)

    assert output(false, "deepseek") ==
             ~s(name="default"  harness="deepseek"  email=nil  org=nil  seat_tier=nil  remaining_percent=nil  weekly_percent=nil  five_hour_percent=nil  freshness="usage_not_polled"  age_ms=nil\n) <>
               ~s(name="work"  harness="deepseek"  usage="usage unavailable"  remaining_percent=nil\n)
  end

  test "json output is unchanged" do
    unmetered = %{"identity" => %{}, "observed_at" => nil, "remaining_percent" => nil, "email" => nil, "org" => nil, "seat_tier" => nil, "weekly_percent" => nil, "five_hour_percent" => nil}

    assert json(output(true, "claude")) == [
             %{
               "name" => "default",
               "harness" => "claude",
               "identity" => %{"email" => "dev@example.com", "organization" => "Example", "seatTier" => "max"},
               "email" => "dev@example.com",
               "org" => "Example",
               "seat_tier" => "max",
               "freshness" => "no_oauth_token",
               "observed_at" => nil,
               "remaining_percent" => nil,
               "age_ms" => nil,
               "weekly_percent" => nil,
               "five_hour_percent" => nil
             }
           ]

    assert json(output(true, "codex")) == [Map.merge(unmetered, %{"name" => "default", "harness" => "codex", "freshness" => "stale_ledger", "age_ms" => 120_000})]

    assert json(output(true, "deepseek")) == [
             Map.merge(unmetered, %{"name" => "default", "harness" => "deepseek", "freshness" => "usage_not_polled", "age_ms" => nil}),
             %{"name" => "work", "harness" => "deepseek", "usage" => "usage unavailable", "identity" => nil, "observed_at" => nil, "remaining_percent" => nil, "age_ms" => nil}
           ]
  end

  defp json(output) do
    assert [line] = String.split(output, "\n", trim: true)
    Jason.decode!(line)
  end
end
