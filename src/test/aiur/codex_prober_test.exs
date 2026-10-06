defmodule Aiur.CodexProberTest do
  use Aiur.TestSupport

  alias Aiur.{CodexProber, Config, ModelAvailability}
  alias Aiur.Codex.AppServerPort

  test "normalizes rate windows nested in the rateLimits response" do
    response = %{
      "rateLimits" => %{
        "primary" => %{"usedPercent" => 4, "windowDurationMins" => 10_080, "resetsAt" => 1_800_000_000},
        "secondary" => %{"usedPercent" => 12, "windowDurationMins" => 60, "resetsAt" => 1_800_000_100},
        "email" => "private@example.test"
      },
      "rateLimitReachedType" => nil
    }

    assert {:ok,
            %{
              "primary" => %{"usedPercent" => 4, "windowDurationMins" => 10_080, "resetsAt" => 1_800_000_000},
              "secondary" => %{"usedPercent" => 12, "windowDurationMins" => 60, "resetsAt" => 1_800_000_100}
            }} = CodexProber.normalize_codex_limits(response)
  end

  test "rejects a response without rate limit windows" do
    assert {:error, :no_usage_data} = CodexProber.normalize_codex_limits(%{"rateLimits" => %{}})
  end

  test "default probe path starts a narrow app-server in an allowed workspace" do
    parent = self()

    assert {:ok, %{"primary" => %{"usedPercent" => 4}}} =
             CodexProber.fetch_limits("codex",
               start_port_fun: fn workspace, nil, nil, nil ->
                 send(parent, {:probe_workspace, workspace})
                 {:ok, :fake_port}
               end,
               initialize_fun: fn :fake_port -> :ok end,
               read_rate_limits_fun: fn :fake_port ->
                 {:ok, %{"rateLimits" => %{"primary" => %{"usedPercent" => 4, "windowDurationMins" => 60}}}}
               end,
               stop_port_fun: fn :fake_port ->
                 send(parent, :probe_port_stopped)
                 :ok
               end
             )

    assert_receive {:probe_workspace, workspace}
    assert String.starts_with?(Path.expand(workspace) <> "/", Path.expand(Config.workspace_root()) <> "/")
    assert {:ok, ^workspace} = AppServerPort.validate_workspace_cwd(workspace, nil)
    assert_receive :probe_port_stopped
    refute File.exists?(workspace)
  end

  test "probe_async executes the provider probe and persists its reading" do
    path = Aiur.TestSupport.tmp_root!("aiur-codex-async-probe") <> ".json"
    on_exit(fn -> File.rm(path) end)
    parent = self()
    now = DateTime.utc_now()

    assert :ok =
             CodexProber.probe_async("codex",
               path: path,
               now: now,
               fetch_limits_fun: fn ->
                 send(parent, :provider_probe_ran)
                 {:ok, %{"rateLimits" => %{"primary" => %{"usedPercent" => 4, "windowDurationMins" => 60}}}}
               end,
               on_complete_fun: &send(parent, {:probe_result, &1})
             )

    assert_receive :provider_probe_ran, 1_000
    assert_receive {:probe_result, result}, 1_000
    assert result == :ok
    assert ModelAvailability.load(path)["backends"]["codex"]["hourly"]["used"] == 4
  end
end
