defmodule AiurWeb.OperatorControlCenter.RunSummaryStripUnknownQuotaTest do
  use ExUnit.Case, async: false

  import AiurWeb.OperatorControlCenter.RunSummaryStripFixtures

  # Future regression guard for the existing cause-neutral failure fallback.
  test "an unrecognized ElevenLabs failure retains neutral copy and hides its payload" do
    quota = %{state: :failed, window: nil, failure: %{secret: "private-failure-detail"}, observed_at: nil}
    row = elevenlabs_row(strip(elevenlabs_quota: quota))

    assert row =~ "Unavailable · the quota could not be read"
    refute row =~ "private-failure-detail"
    refute row =~ "the API key was rejected"
  end
end
