Code.require_file("executor_control_center_docs_meter_source.exs", __DIR__)

Code.require_file("executor_control_center_docs_provider.exs", __DIR__)
Code.require_file("executor_control_center_docs_data.exs", __DIR__)
Code.require_file("executor_control_center_docs_fleet.exs", __DIR__)

defmodule Aiur.Docs.ControlCenterFixture do
  alias Aiur.Docs.ControlCenterFixture.MeterSource
  import Aiur.Docs.ControlCenterFixture.Data
  import Aiur.Docs.ControlCenterFixture.Fleet
  alias Aiur.Docs.ControlCenterFixture.{Data, Fleet}
  alias Aiur.Docs.ControlCenterFixture.Provider
  alias Aiur.GitHub.Quota
  alias Aiur.Orchestrator.SnapshotStore
  alias AiurWeb.FinancialDataAccess.Generation

  @port String.to_integer(System.get_env("AIUR_DOCS_PORT", "4099"))

  def run do
    tmp = System.fetch_env!("AIUR_DOCS_TMP")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "telemetry.ndjson"), "{}\n")
    File.write!(Path.join(tmp, "config"), synthetic_workflow(tmp))
    Process.put(:fixture_now, DateTime.utc_now() |> DateTime.truncate(:second))

    Application.put_env(:aiur, :log_file, Path.join(tmp, "aiur.log"))
    Application.put_env(:aiur, :workflow_file_path, Path.join(tmp, "config"))

    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:phoenix_live_view)

    {:ok, _} =
      Supervisor.start_link(
        [{Phoenix.PubSub, name: Aiur.PubSub}, {Task.Supervisor, name: Aiur.TaskSupervisor}],
        strategy: :one_for_one
      )

    decisions = decisions()

    # Documentation captures use SYNTHETIC provider meters only. The real
    # `Aiur.ProviderMeterRefresh` / `Aiur.ProviderMeterProjection` pair probes
    # the operator's own Claude and Codex accounts over HTTP with ambient
    # credentials, so it is deliberately never started here — no `:req`, no
    # meter store, no account generation server. The endpoint's
    # `:provider_meter_source` seam points at
    # `Aiur.Docs.ControlCenterFixture.MeterSource` instead, which is pure data.
    #
    # Dashboard auth stays configured because the meter cards sit behind the
    # financial-data capability and that capability is only granted to a session
    # carrying a real proof. The credentials are the fixed example pair the
    # capture script sends; they guard nothing but a loopback fixture.
    System.put_env("AIUR_DASHBOARD_USERNAME", "example")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "example")

    # Without this the credential check cannot mint a configuration generation,
    # so it returns :error and every request 401s regardless of what is typed.
    {:ok, _} = Generation.start_link([])
    {:ok, _} = AiurWeb.FinancialData.start_link([])

    configure_build_order_pack(tmp)
    start_github_quota(tmp)

    start_provider(:docs_orchestrator, snapshot: fleet_snapshot())
    publish_fleet_snapshot()

    start_provider(:docs_decisions,
      decisions: decisions,
      history: history(),
      snapshot: %{}
    )

    start_provider(:docs_metrics,
      metrics: metrics(decisions),
      snapshot: %{}
    )

    start_provider(:docs_merges,
      snapshot: %{
        merges: recent_merges(),
        health: :writable,
        reconciliation: %{status: :complete, partial?: false, pages_fetched: 2}
      }
    )

    configure_endpoint()
    {:ok, _} = AiurWeb.Endpoint.start_link()

    IO.puts("Operator Control Center docs fixture ready at http://127.0.0.1:#{@port}")
    Process.sleep(:infinity)
  end

  # The Units page reads its fleet from `SnapshotStore`, not from the
  # orchestrator process, so a provider that only answers `:snapshot` renders an
  # empty page. Publish the synthetic fleet into the read model and keep
  # republishing it: a retained snapshot ages out after two minutes and would
  # otherwise be captured behind a "last known good" staleness banner.
  defp publish_fleet_snapshot do
    snapshot = fleet_snapshot()
    _generation = SnapshotStore.begin_generation(:docs_orchestrator)
    :ok = SnapshotStore.publish(:docs_orchestrator, snapshot)

    spawn_link(fn ->
      Stream.repeatedly(fn ->
        Process.sleep(60_000)
        SnapshotStore.publish(:docs_orchestrator, snapshot)
      end)
      |> Stream.run()
    end)

    :ok
  end

  defp start_provider(name, opts) do
    {:ok, _} = Provider.start_link(Keyword.put(opts, :name, name))
  end

  defp configure_endpoint do
    writable = System.get_env("AIUR_DOCS_WRITABLE", "false") == "true"

    config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        server: true,
        http: [ip: {127, 0, 0, 1}, port: @port],
        url: [host: "127.0.0.1", port: @port],
        secret_key_base: String.duplicate("d", 64),
        dashboard_writable: writable,
        # Auth on: the meter cards are gated behind the financial-data
        # capability, which is only granted to a session carrying a real proof.
        dashboard_auth_required: true,
        orchestrator: :docs_orchestrator,
        decision_store: :docs_decisions,
        decision_metrics: :docs_metrics,
        recent_merge_store: :docs_merges,
        control_center_cache: false,
        snapshot_timeout_ms: 1_000,
        # The Units catalog joins current-run membership, ticket activity, and
        # the open-ticket listing. All three read GitHub in production, so all
        # three are replaced by synthetic readers here.
        units_membership_fun: &Data.units_membership/0,
        units_activity_fun: &Data.units_activity/0,
        # Never the real projection — see MeterSource's documentation-safety note.
        provider_meter_source: MeterSource,
        streamdeck_provider_meters_fun: &MeterSource.streamdeck_meters/0,
        # The Stream Deck emulator projects its own fleet snapshot rather than
        # the Units orchestrator bucket list, so it gets a dedicated synthetic
        # fleet wide enough to fill the eight-key grid and its pager.
        streamdeck_fixture_fleet: true,
        streamdeck_snapshot_fun: &Fleet.streamdeck_snapshot/0,
        agent_chat_pause_fun: &Fleet.streamdeck_noop/1,
        agent_chat_resume_fun: &Fleet.streamdeck_noop/1
      )
      |> Keyword.delete(:streamdeck_logs_fun)

    Application.put_env(:aiur, AiurWeb.Endpoint, config)
  end

  # --- GitHub quota ----------------------------------------------------------

  # The run summary strip reads `Aiur.GitHub.Quota`. Left unstarted it reads
  # "Awaiting GitHub response"; started with its default options it would poll
  # GitHub with the operator's credential. It is started here with refreshing
  # disabled, alerts silenced, and its on-disk state confined to the fixture's
  # temporary directory, then fed one synthetic budget observation.
  defp start_github_quota(tmp) do
    {:ok, _} =
      Quota.start_link(
        refresh?: false,
        emit_fun: fn _kind, _payload -> :ok end,
        shell_log_path: Path.join(tmp, "github-shell-quota.ndjson"),
        hold_dir: Path.join(tmp, "github-holds")
      )

    reset = DateTime.utc_now() |> DateTime.add(1_920, :second) |> DateTime.to_unix()

    Quota.observe(%{}, {
      :ok,
      %{
        body: %{
          "resources" => %{
            "core" => %{"limit" => 5_000, "remaining" => 4_180, "reset" => reset},
            "graphql" => %{"limit" => 5_000, "remaining" => 3_640, "reset" => reset}
          }
        }
      }
    })

    :ok
  end

  # --- Units catalog ---------------------------------------------------------

  # Every synthetic unit, in the display order the Units table shows them, with
  # the lifecycle and progress each row should present.
end

Aiur.Docs.ControlCenterFixture.run()
