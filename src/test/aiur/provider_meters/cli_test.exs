defmodule Aiur.ProviderMeters.CLITest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Aiur.ProviderMeters.CLI

  test "unverified over-quota reading keeps raw amount, bounded bar, scope and age" do
    view = %{state: :observed, identity_scope: :host_unverified, age_seconds: 17, windows: %{"current" => %{kind: :rate_limit, used_percent: 123.5}}}
    text = capture_io(fn -> CLI.print({:muse, view}) end)
    assert text =~ "██████████ 124%"
    assert text =~ "17s ago"
    assert text =~ "[current host; account unverified]"
  end

  test "unknown host reading has no zero bar or invented observation age" do
    text = capture_io(fn -> CLI.print({:muse, %{state: :unknown, identity_scope: :host_unverified}}) end)
    assert text =~ "no observation yet"
    assert text =~ "account unverified"
    refute text =~ "0%"
    refute text =~ "ago"
  end

  test "percentage windows retain their reset time in CLI output" do
    reset = DateTime.add(DateTime.utc_now(), 2 * 86_400 + 1_800, :second)
    view = %{state: :observed, age_seconds: 17, windows: %{"current" => %{kind: :rate_limit, used_percent: 33, resets_at: reset}}}

    text = capture_io(fn -> CLI.print({:muse, view}) end)
    assert text =~ "33%"
    assert text =~ "resets in 2d 0h"
    assert text =~ "17s ago"
  end

  test "a failed refresh labels retained consumption as stale even when recently observed" do
    view = %{
      state: :observed,
      identity_scope: :host_unverified,
      freshness: :stale,
      age_seconds: 17,
      windows: %{"current" => %{kind: :rate_limit, used_percent: 33}}
    }

    text = capture_io(fn -> CLI.print({:muse, view}) end)
    assert text =~ "33%"
    assert text =~ "17s ago"
    assert text =~ "stale"
    assert text =~ "account unverified"
  end
end
