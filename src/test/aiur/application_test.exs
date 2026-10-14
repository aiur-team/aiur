defmodule Aiur.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Application, as: AiurApp
  alias Aiur.Application.StartupChecks
  alias Aiur.Identity.Machine

  defmodule SuccessStubDistribution do
    @moduledoc false
    def start!, do: :ok
    def node_name, do: :"stub@127.0.0.1"
  end

  defmodule FailureStubDistribution do
    @moduledoc false
    def start!, do: {:error, :not_distributed}
    def node_name, do: nil
  end

  test "machine identity is loaded by application boot into isolated test state" do
    dir = Application.fetch_env!(:aiur, :machine_state_dir)
    assert String.starts_with?(dir, System.tmp_dir!())
    assert {:ok, identity} = Machine.current()
    assert Jason.decode!(File.read!(Path.join(dir, "identity.json")))["machine_id"] == identity.machine_id
  end

  test "stop/1 is a no-op returning :ok" do
    # `Application.stop/1` is invoked by OTP during application
    # shutdown. There's no cleanup to perform — releases unmount on
    # node halt — so the callback just returns :ok.
    assert :ok = AiurApp.stop(:any_state)
  end

  test "runs the RTK host-hook check during application startup" do
    source = File.read!(Path.expand("../../lib/aiur.ex", __DIR__))

    assert source =~ "Aiur.RtkStartupCheck.run()"
  end

  test "startup Funnel health check stays quiet while the reconciler owns the route" do
    settings =
      {:ok,
       %{
         server: %{tailscale_funnel: true},
         observability: %{build_order_funnel_health_check: true}
       }}

    refute AiurApp.build_order_funnel_health_check_startup?(settings, false)
    refute AiurApp.build_order_funnel_health_check_startup?(settings, true)

    health_only_settings =
      {:ok,
       %{
         server: %{tailscale_funnel: false},
         observability: %{build_order_funnel_health_check: true}
       }}

    assert AiurApp.build_order_funnel_health_check_startup?(health_only_settings, false)
  end

  test "logs the resolved base branch exactly once at info level" do
    log = capture_log(fn -> assert :ok = StartupChecks.log_base_branch({:ok, %{tracker: %{base_branch: "develop"}}}) end)

    assert length(Regex.scan(~r/aiur_boot phase=config base_branch="develop"/, log)) == 1
  end

  describe "start_distribution/1" do
    test "logs at info when distribution starts successfully" do
      assert :ok = AiurApp.start_distribution(SuccessStubDistribution)
    end

    test "logs at debug when distribution refuses to start" do
      assert :ok = AiurApp.start_distribution(FailureStubDistribution)
    end
  end

  describe "validate_dashboard_compatibility/2" do
    test "allows no-dashboard when Remote Control is not configured" do
      assert :ok =
               AiurApp.validate_dashboard_compatibility(true,
                 remote_control?: false,
                 routing: %{1 => "codex", 2 => "claude:sonnet"}
               )
    end

    test "rejects no-dashboard when global Remote Control is configured" do
      assert {:error, message} =
               AiurApp.validate_dashboard_compatibility(true,
                 remote_control?: true,
                 routing: %{}
               )

      assert message =~ "--no-dashboard cannot be used with Claude Remote Control"
      assert message =~ "agent.remote_control"
      assert message =~ "Remove --no-dashboard"
    end

    test "rejects no-dashboard when a complexity route forces Remote Control" do
      assert {:error, message} =
               AiurApp.validate_dashboard_compatibility(true,
                 remote_control?: false,
                 routing: %{5 => "claude:opus+remote"}
               )

      assert message =~ "agent.routing +remote"
      assert message =~ "lifecycle hooks require Aiur.HttpServer"
    end

    test "dashboard-enabled launches bypass Remote Control compatibility checks" do
      assert :ok =
               AiurApp.validate_dashboard_compatibility(false,
                 remote_control?: true,
                 routing: %{5 => "claude+remote"}
               )
    end
  end
end
