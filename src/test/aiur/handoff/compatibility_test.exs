defmodule Aiur.Handoff.CompatibilityTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.Handoff, as: RunnerHandoff
  alias Aiur.Handoff.{Compatibility, Fallback}

  test "a departed relay under a long state path falls back without a socket argument exit" do
    agent = %{"transport" => %{"kind" => "relay", "protocol" => 1, "directory" => Path.join(System.tmp_dir!(), String.duplicate("missing", 30))}}
    assert {:error, :relay_gone} = Compatibility.check(agent, %{}, config_fingerprint: "same")
    assert {:error, :relay_socket_missing} = Fallback.stop(agent)
  end

  test "an in-daemon record whose saved conversation decodes is compatible" do
    dir = workspace()

    agent =
      in_daemon_agent(dir, RunnerHandoff.encode(%{"messages" => [], "interrupted" => false}))

    assert :ok = Compatibility.check(agent, %{}, config_fingerprint: "same")
  end

  test "a damaged in-daemon snapshot is rejected instead of seeding a partial conversation" do
    dir = workspace()

    assert {:error, :provider_state_invalid} =
             Compatibility.check(in_daemon_agent(dir, "not-a-snapshot"), %{}, config_fingerprint: "same")
  end

  test "an in-daemon record whose backend no longer declares in-daemon handoff falls back" do
    dir = workspace()

    agent =
      dir
      |> in_daemon_agent(RunnerHandoff.encode(%{"messages" => [], "interrupted" => false}))
      |> Map.put("backend", "claude")

    assert {:error, :backend_unsupported} = Compatibility.check(agent, %{}, config_fingerprint: "same")
  end

  defp in_daemon_agent(dir, encoded) do
    %{
      "transport" => %{"kind" => "in_daemon", "provider_state" => encoded},
      "backend" => "openrouter",
      "workspace" => dir,
      "config_fingerprint" => "same"
    }
  end

  defp workspace do
    dir = Path.join(System.tmp_dir!(), "compat-in-daemon-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    dir
  end
end
