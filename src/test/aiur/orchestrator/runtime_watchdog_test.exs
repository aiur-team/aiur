defmodule Aiur.Orchestrator.RuntimeWatchdogTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.RuntimeWatchdog

  test "excludes paused entries from duration overrun" do
    now = DateTime.utc_now()
    entry = %{started_at: DateTime.add(now, -120, :second), control: %{status: :paused}}

    refute RuntimeWatchdog.overrunning_entry?(entry, now, 1)
  end
end
