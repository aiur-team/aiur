defmodule Aiur.CapabilitiesCLITest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  defp report do
    %{
      contract: "aiur.capabilities",
      contract_version: 1,
      boot_id: "boot",
      revision: 7,
      observed_at: "2026-10-09T12:00:00Z",
      age_ms: 840,
      freshness: "current",
      min_client_versions: %{},
      machine: %{label: "workstation", machine_id: "machine"},
      instance: %{instance_id: "machine/key", aiur_version: "0.0.9", run_shape: %{http_listener: false}},
      repository: %{kind: "github", owner: "aiur-team", name: "aiur"},
      executor: %{state: :active, consumer_id: "host-key"},
      capabilities: %{
        "voice.stt" => %{state: :unavailable, reason: :not_configured, depends_on: ["api.http"]},
        "api.http" => %{state: :available, reason: nil}
      }
    }
  end

  test "renders identity, age, freshness, sorted states, reasons and dependencies" do
    output = capture_io(fn -> assert Aiur.CapabilitiesCLI.run(report_fun: &report/0) == 0 end)
    assert output =~ "workstation / machine/key (revision 7, observed 0.84s ago, current)"
    assert output =~ "repository   github aiur-team/aiur"
    assert output =~ "executor     active  host-key"
    assert [api, voice] = output |> String.split("\n") |> Enum.filter(&String.contains?(&1, ["api.http ", "voice.stt "]))
    assert api == String.pad_trailing("api.http", 25) <> "available"
    assert voice == String.pad_trailing("voice.stt", 25) <> "unavailable  not_configured (needs api.http)"
  end

  test "stale and null sections retain their uncertainty" do
    report = %{report() | age_ms: 7_000, freshness: "stale", machine: nil, instance: nil, executor: nil, repository: nil}
    output = Aiur.CapabilitiesCLI.render(report)
    assert output =~ "unknown / unknown"
    assert output =~ "observed 7.0s ago, stale"
    assert output =~ "repository   unknown"
    assert output =~ "executor     unknown  unknown"
  end

  test "control facade prints the report and successful RPC exit marker" do
    output = capture_io(fn -> assert Aiur.AgentControlCLI.capabilities(report_fun: &report/0) == :ok end)
    assert output =~ "workstation / machine/key"
    assert String.ends_with?(output, "__AIUR_CONTROL_EXIT__:0\n")
  end

  test "JSON uses the shared wire report without a CLI envelope" do
    report = report()
    output = capture_io(fn -> assert Aiur.CapabilitiesCLI.run(json: true, report_fun: fn -> report end) == 0 end)
    wire = Jason.decode!(output)
    assert wire == Aiur.Capabilities.to_wire(report)
    assert wire["capabilities"]["voice.stt"]["state"] == "unavailable"
    assert wire["age_ms"] == 840
    assert wire["executor"]["state"] == "active"
  end
end
