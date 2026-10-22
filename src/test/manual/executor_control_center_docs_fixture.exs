Code.require_file("executor_control_center_docs_meter_source.exs", __DIR__)

Code.require_file("executor_control_center_docs_provider.exs", __DIR__)
Code.require_file("executor_control_center_docs_data.exs", __DIR__)
Code.require_file("executor_control_center_docs_fleet.exs", __DIR__)

# The Build home page renders the frozen `live` dataset the design-parity harness
# uses, so its capture reads no history store, tracker or provider meter.
for file <- ~w(earlier_control fixture_source fixture_conversation_source),
    do: Code.require_file("../support/build_home/#{file}.ex", __DIR__)

defmodule Aiur.Docs.ControlCenterFixture.BuildSource do
  @moduledoc """
  The frozen `live` design dataset, with agent states limited to ones the daemon
  emits. The design's "retries" card has no server path, so the docs show it as
  an error instead of documenting a state operators never see.
  """
  @behaviour AiurWeb.Build.DataSource
  alias Aiur.TestSupport.BuildHome.FixtureSource

  @impl true
  def subscribe(opts), do: FixtureSource.subscribe(opts)

  @impl true
  def snapshot(opts), do: with({:ok, data} <- FixtureSource.snapshot(opts), do: {:ok, update_in(data, ["sections", "now"], &Enum.map(&1, fn row -> emitted(row) end))})

  @impl true
  def earlier(before, zone, opts), do: FixtureSource.earlier(before, zone, opts)

  @impl true
  def ticket(id, opts), do: with({:ok, row} <- FixtureSource.ticket(id, opts), do: {:ok, emitted(row)})

  defp emitted(%{"agent" => %{"state" => "retries"}} = row), do: put_in(row, ["agent", "state"], "error")
  defp emitted(row), do: row
end

defmodule Aiur.Docs.ControlCenterFixture do
  alias Aiur.Docs.ControlCenterFixture.MeterSource
  import Aiur.Docs.ControlCenterFixture.Data
  import Aiur.Docs.ControlCenterFixture.Fleet
  alias Aiur.Docs.ControlCenterFixture.{BuildSource, Data, Fleet}
  alias Aiur.Docs.ControlCenterFixture.Provider
  alias Aiur.GitHub.Quota
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.TestSupport.BuildHome.{FixtureConversationSource, FixtureSource}
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

    # `SnapshotCache` owns the ETS table `SnapshotStore.publish/2` writes the fleet into.
    {:ok, _} =
      Supervisor.start_link(
        [{Phoenix.PubSub, name: Aiur.PubSub}, {Task.Supervisor, name: Aiur.TaskSupervisor}, Aiur.Orchestrator.SnapshotCache],
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
    configure_build_home()
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

  defp configure_build_home do
    Application.put_env(:aiur, :build_data_source, BuildSource)
    Application.put_env(:aiur, :build_fixture_dataset, "live")
    Application.put_env(:aiur, :build_conversation_source, FixtureConversationSource)
    FixtureSource.configure_usage(:ok)
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
