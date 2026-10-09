defmodule Aiur.RunTelemetry.CaptureSettingTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.{Config, RunTelemetry}
  alias Aiur.RunTelemetry.Summaries
  alias AiurWeb.Endpoint

  @endpoint Endpoint

  setup do
    root = Aiur.TestSupport.tmp_root!("capture-setting")
    File.mkdir_p!(root)
    prior_root = Application.fetch_env(:aiur, :repo_base_root)
    prior_repo = Application.fetch_env(:aiur, :analytics_repo)
    prior_endpoint = Application.fetch_env(:aiur, Endpoint)
    prior_file = Application.fetch_env(:aiur, :analytics_telemetry_file)
    prior_terms = Enum.map([{RunTelemetry, :telemetry_enabled}, {RunTelemetry, :boot_state}], &{&1, :persistent_term.get(&1, :unset)})
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :analytics_repo, "capture/test")
    Application.put_env(:aiur, :analytics_telemetry_file, Path.join(root, "absent.ndjson"))

    on_exit(fn ->
      reset_env(:repo_base_root, prior_root)
      reset_env(:analytics_repo, prior_repo)
      reset_env(Endpoint, prior_endpoint)
      reset_env(:analytics_telemetry_file, prior_file)

      Enum.each(prior_terms, fn
        {key, :unset} -> :persistent_term.erase(key)
        {key, value} -> :persistent_term.put(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root, gaps: Path.join(Summaries.analytics_dir(), "capture-gaps.ndjson")}
  end

  test "GitHub fact capture defaults on through the config loader" do
    assert Config.capture_github_facts?() == true
  end

  test "GitHub fact capture honors explicit false through the config loader" do
    configure("capture_github_facts: false")
    assert Config.capture_github_facts?() == false
    assert Config.telemetry_enabled?() == true
  end

  test "GitHub fact capture fails open for an unreadable config" do
    File.rm!(Workflow.workflow_file_path())
    assert {:error, _reason} = Config.settings_uncached()
    assert Config.capture_github_facts?() == true
  end

  test "disabled boot appends exactly one identified gap and preserves prior gaps", %{gaps: gaps} do
    File.mkdir_p!(Path.dirname(gaps))
    File.write!(gaps, "{\"boot_id\":\"previous\"}\n")
    configure("telemetry_enabled: false")
    assert :ok = RunTelemetry.start_boot()
    assert RunTelemetry.telemetry_enabled?() == false
    assert [previous, current] = gaps |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert previous == %{"boot_id" => "previous"}

    assert current == %{
             "boot_id" => RunTelemetry.boot_id(),
             "started_at" => DateTime.to_iso8601(RunTelemetry.boot_started_at()),
             "telemetry_enabled" => false
           }
  end

  test "enabled boot creates no capture gap (future regression guard)", %{gaps: gaps} do
    assert :ok = RunTelemetry.start_boot()
    assert RunTelemetry.telemetry_enabled?() == true
    refute File.exists?(gaps)
  end

  test "gap write failure is logged without stopping boot", %{root: root} do
    configure("telemetry_enabled: false")
    obstruction = Path.join(root, "not-a-directory")
    File.write!(obstruction, "keep")
    Application.put_env(:aiur, :repo_base_root, obstruction)
    assert capture_log(fn -> assert :ok = RunTelemetry.start_boot() end) =~ "capture_gap_write_failed"
    assert RunTelemetry.telemetry_enabled?() == false
    assert File.read!(obstruction) == "keep"
  end

  test "analytics notice follows boot capture state even if the config changes" do
    config = Application.get_env(:aiur, Endpoint, [])
    Application.put_env(:aiur, Endpoint, Keyword.merge(config, server: false, secret_key_base: String.duplicate("s", 64), dashboard_auth_required: false))
    Aiur.TestSupport.start_owned_endpoint!()

    configure("telemetry_enabled: false")
    RunTelemetry.start_boot()
    configure("telemetry_enabled: true")
    {:ok, disabled, html} = live(build_conn(), "/analytics")
    assert has_element?(disabled, "#analytics-capture-off")
    assert html =~ "Analytics capture is off (observability.telemetry_enabled: false). Experiments will have no data for this period."

    RunTelemetry.start_boot()
    {:ok, enabled, _html} = live(build_conn(), "/analytics")
    refute has_element?(enabled, "#analytics-capture-off")
  end

  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  defp reset_env(key, :error), do: Application.delete_env(:aiur, key)
  defp reset_env(key, {:ok, value}), do: Application.put_env(:aiur, key, value)

  defp configure(setting) do
    File.write!(Workflow.workflow_file_path(), "tracker:\n  kind: memory\nobservability:\n  #{setting}\n")
    :ok = WorkflowStore.force_reload()
  end
end
