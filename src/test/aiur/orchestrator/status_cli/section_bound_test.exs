Code.require_file(Path.expand("../control_cli/fixture.exs", __DIR__))

defmodule Aiur.OrchestratorStatusCliSectionBoundTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Orchestrator.ControlCLI.TestFixture
  alias Aiur.Orchestrator.SnapshotCache
  alias Aiur.Orchestrator.StatusCLI

  setup context do
    SnapshotCache.delete({:status_section, :supervision})

    on_exit(fn ->
      Application.delete_env(:aiur, :supervision_health_status_fun)
      SnapshotCache.delete({:status_section, :supervision})
    end)

    TestFixture.setup(context)
  end

  defp stub_supervision(fun), do: Application.put_env(:aiur, :supervision_health_status_fun, fun)

  defp hung_supervision do
    stub_supervision(fn ->
      receive do
        :never -> {:ok, %{expected: 2, healthy: 2, missing: []}}
      end
    end)
  end

  test "a section past its bound renders its last good output with a stale age instead of waiting" do
    stub_supervision(fn -> {:ok, %{expected: 2, healthy: 1, missing: [%{id: Aiur.Events.IdGenerator, reason: :killed}]}} end)
    fresh = capture_io(fn -> StatusCLI.status(section_timeout_ms: 2_000) end)
    assert fresh =~ "SUPERVISION 1/2 — Aiur.Events.IdGenerator DOWN"
    refute fresh =~ "STALE SUPERVISION"

    hung_supervision()
    started_ms = System.monotonic_time(:millisecond)
    stale = capture_io(fn -> StatusCLI.status(section_timeout_ms: 200) end)

    assert System.monotonic_time(:millisecond) - started_ms < 2_000
    assert stale =~ "STALE SUPERVISION — showing the last good output, 0s old (no reply within 200ms)\nSUPERVISION 1/2 — Aiur.Events.IdGenerator DOWN"
    # The served output keeps the exit code it was read with.
    assert stale =~ "__AIUR_CONTROL_EXIT__:1"
  end

  test "the stale label renders the age of the served output" do
    SnapshotCache.put({:status_section, :supervision}, %{
      output: "SUPERVISION 2/2 healthy\n",
      value: 0,
      at_ms: System.monotonic_time(:millisecond) - 42_000
    })

    hung_supervision()
    output = capture_io(fn -> StatusCLI.status(section_timeout_ms: 200) end)

    assert output =~ "STALE SUPERVISION — showing the last good output, 42s old (no reply within 200ms)\nSUPERVISION 2/2 healthy"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
  end

  test "a section past its bound with no earlier output is unavailable, not healthy" do
    hung_supervision()
    output = capture_io(fn -> StatusCLI.status(section_timeout_ms: 200) end)

    assert output =~ "SUPERVISION unavailable (no reply within 200ms and no earlier output)"
    refute output =~ "SUPERVISION 2/2 healthy"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end
end
