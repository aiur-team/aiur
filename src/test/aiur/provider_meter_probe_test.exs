defmodule Aiur.ProviderMeterProbeTest do
  # These tests subscribe to shared provider-meter topics, so running alongside
  # other publisher cases lets foreign snapshots satisfy their receive checks.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Accounts.Shims.Claude, as: ClaudeAccounts
  alias Aiur.Accounts.UsageReadings
  alias Aiur.Claude.UsageApi
  alias Aiur.ProviderMeterProbe
  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeters.Events
  alias Aiur.ProviderMeterSnapshot

  defmodule FakeAgent do
    @moduledoc false

    def start_session(workspace, opts) do
      case Process.get(:probe_start_result, :ok) do
        :ok ->
          notify({:session_started, Keyword.get(opts, :identifier)})
          notify({:session_workspace, workspace})
          {:ok, %{fake: true}}

        {:error, _reason} = error ->
          error

        :raise ->
          raise "app-server unavailable"
      end
    end

    def stop_session(session) do
      notify({:session_stopped, session})
      :ok
    end

    defp notify(message) do
      case Process.get(:probe_test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  defmodule FakeUsageApi do
    @moduledoc false
    def fetch(_opts), do: {:error, :usage_unavailable}
  end

  defmodule MultiWindowUsageApi do
    @moduledoc false
    def fetch(_opts) do
      {:ok,
       %{
         used_percent: 21,
         resets_at: ~U[2026-09-01 18:00:00Z],
         window: "five_hour",
         windows: [
           %{
             window: "seven_day",
             label: "Weekly (all models)",
             scope: :weekly,
             priority: 0,
             coverage: :supported,
             used_percent: 5,
             resets_at: ~U[2026-09-03 18:00:00Z]
           },
           %{
             window: "five_hour",
             label: "Session (5-hour)",
             scope: :session,
             priority: 3,
             coverage: :supported,
             used_percent: 21,
             resets_at: ~U[2026-09-01 18:00:00Z]
           }
         ]
       }}
    end
  end

  defmodule CachedUsageApi do
    @moduledoc false
    def fetch(_opts), do: raise("metadata-aware usage fetching is required")

    def fetch_with_metadata(_opts) do
      {:ok, reading} = MultiWindowUsageApi.fetch([])
      {:ok, reading, %{freshness: :cached, observed_at: ~U[2026-10-01 00:00:00Z]}}
    end
  end

  defmodule MultiAccountUsageApi do
    @moduledoc false
    def fetch(_opts), do: raise("metadata-aware usage fetching is required")

    def fetch_with_metadata(opts) do
      send(Process.get(:probe_test_pid), {:account_credentials, opts[:credentials_path], opts[:cache_key]})
      {:ok, reading} = MultiWindowUsageApi.fetch([])
      {:ok, reading, %{freshness: :fresh, observed_at: ~U[2026-10-01 00:00:00Z]}}
    end
  end

  defmodule ObservingFakeAgent do
    @moduledoc false

    def start_session(_workspace, _opts) do
      observed_at = DateTime.utc_now()

      snapshot = %ProviderMeterSnapshot{
        provider: :codex,
        backend: :app_server,
        provider_account_generation: "gen-1",
        observed_at: observed_at,
        auth_mode: :subscription,
        freshness: :fresh,
        health: %{state: :healthy, failure: nil, last_observed_at: observed_at, last_source_version: 1},
        windows: %{"session" => %{kind: :rate_limit, used_percent: 10}}
      }

      send(Process.get(:probe_projection), {:provider_meter_changed, snapshot})
      {:ok, %{fake: true}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule ExplodingCloseAgent do
    @moduledoc false

    def start_session(_workspace, _opts) do
      send(Process.get(:probe_test_pid), {:session_started, "usage-probe"})
      {:ok, %{fake: true}}
    end

    def stop_session(_session), do: raise("close failed")
  end

  defmodule ExitingAgent do
    @moduledoc false

    def start_session(_workspace, _opts) do
      exit({:timeout, {GenServer, :call, [:app_server, :start_session, 5_000]}})
    end

    def stop_session(_session), do: :ok
  end

  defmodule OddReturnAgent do
    @moduledoc false

    def start_session(_workspace, _opts), do: :something_unexpected
    def stop_session(_session), do: :ok
  end

  setup do
    UsageReadings.reset()
    on_exit(&UsageReadings.reset/0)
    projection = :"probe_proj_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({ProviderMeterProjection, [name: projection, subscribe?: false]})

    Process.put(:probe_test_pid, self())
    Process.put(:probe_projection, pid)

    %{projection: projection, pid: pid}
  end

  defp opts(ctx, extra \\ []) do
    Keyword.merge(
      [
        projection: ctx.projection,
        workspace: "/tmp/aiur-probe-test",
        observation_window_ms: 60,
        probe_agent: FakeAgent,
        # Pinned so the probe's dispatch gate reads a fixture rather than the
        # daemon's live config, which other suites mutate.
        backend_configs: %{}
      ],
      extra
    )
  end

  test "a probe opens a session and closes it again", ctx do
    ProviderMeterProbe.observe(:codex, opts(ctx))

    assert_received {:session_started, "usage-probe"}
    assert_received {:session_stopped, %{fake: true}}
  end

  # The session must close even when nothing was observed, or a failed probe
  # leaks a provider process on every refresh tick.
  test "the session closes even when the provider pushes nothing", ctx do
    assert [%{observed?: false, reason: nil}] = ProviderMeterProbe.observe(:codex, opts(ctx))

    assert_received {:session_stopped, %{fake: true}}
  end

  test "an observation arriving during the window is reported as observed", ctx do
    [outcome] =
      ProviderMeterProbe.observe(
        :codex,
        opts(ctx, observation_window_ms: 2_000, probe_agent: ObservingFakeAgent)
      )

    assert outcome.observed? == true
    assert outcome.reason == nil
  end

  test "a session that cannot start reports why instead of raising", ctx do
    Process.put(:probe_start_result, {:error, :app_server_unavailable})

    assert [%{observed?: false, reason: :app_server_unavailable}] = ProviderMeterProbe.observe(:codex, opts(ctx))

    refute_received {:session_stopped, _session}
  end

  test "a failed probe records its result on the consumer projection", ctx do
    send(ctx.pid, {:provider_meter_changed, snapshot(:codex, ~U[2026-07-24 12:00:00Z])})
    Process.put(:probe_start_result, {:error, :port_closed})

    assert [%{provider: :codex, observed?: false, reason: :port_closed}] =
             ProviderMeterProbe.observe(:codex, opts(ctx, observed_at: ~U[2026-07-27 12:00:00Z]))

    view = ProviderMeterProjection.provider_view(ctx.projection, :codex)
    assert view.freshness == :stale
    assert view.health.failure == :port_closed
    assert view.health.last_attempt_at == ~U[2026-07-27 12:00:00Z]
    assert view.health.consecutive_failures == 1
  end

  # Containment is unchanged; what the operator is told is not. A raising
  # adapter names itself `:probe_crashed` all the way through to the
  # projection's `health.failure`, where it used to be indistinguishable from a
  # provider that simply never answered.
  test "a raising session start is contained and surfaces as a crash, not an outage", ctx do
    Process.put(:probe_start_result, :raise)

    log =
      capture_log(fn ->
        assert [%{observed?: false, reason: :probe_crashed}] =
                 ProviderMeterProbe.observe(:codex, opts(ctx, observed_at: ~U[2026-07-27 12:00:00Z]))
      end)

    assert log =~ "provider meter probe crashed"
    assert log =~ "provider=:codex"

    view = ProviderMeterProjection.provider_view(ctx.projection, :codex)
    assert view.health.failure == :probe_crashed
  end

  # The split has to cut both ways. An app-server that is slow or absent exits
  # the caller's `GenServer.call`; that is the provider not answering, and
  # relabelling it a crash would spam a stacktrace every probe cycle while the
  # app-server is down — the same miscategorisation running the other way.
  test "an app-server that never answers reports a timeout, not a crash", ctx do
    log =
      capture_log(fn ->
        assert [%{observed?: false, reason: :timeout}] =
                 ProviderMeterProbe.observe(:codex, opts(ctx, probe_agent: ExitingAgent))
      end)

    refute log =~ "provider meter probe crashed"
  end

  # A meter that publishes only the worst-consumed window shows whichever
  # window happens to be highest — usually the five-hour session one, which
  # resets constantly. Every reported window must be published so the surface
  # can lead with the weekly standing.
  test "the usage-api probe publishes every reported window, not only the worst", ctx do
    :ok = Events.subscribe_observed()

    assert [%{provider: :claude, observed?: true}] =
             ProviderMeterProbe.observe(:claude, opts(ctx, usage_api: MultiWindowUsageApi))

    assert_receive {:provider_meter_changed, %ProviderMeterSnapshot{provider: :claude, windows: windows}}, 1000

    assert Map.keys(windows) |> Enum.sort() == ["five_hour", "seven_day"]

    weekly = windows["seven_day"]
    assert weekly.used_percent == 5
    assert weekly.priority == 0
    assert weekly.limit_id == "seven_day"
    assert weekly.kind == :rate_limit
    assert weekly.resets_at == ~U[2026-09-03 18:00:00Z]

    assert windows["five_hour"].used_percent == 21
    assert windows["five_hour"].priority == 3
  end

  test "per-account polling preserves cache freshness and original observation time", ctx do
    assert [%{provider: :claude, observed?: true}] =
             ProviderMeterProbe.observe(:claude, opts(ctx, usage_api: CachedUsageApi))

    assert %{"default" => %{freshness: :cached, observed_at: ~U[2026-10-01 00:00:00Z]}} =
             UsageReadings.snapshot("claude", ["default"])
  end

  test "per-account polling uses a separate credentials path and reading for each account", ctx do
    assert [%{provider: :claude, observed?: true}] =
             ProviderMeterProbe.observe(
               :claude,
               opts(ctx,
                 usage_api: MultiAccountUsageApi,
                 claude_accounts: ["default", "max"],
                 claude_profiles: %{"max" => "/profiles/max"}
               )
             )

    assert_receive {:account_credentials, default_credentials, default_cache_key}, 1000
    assert_receive {:account_credentials, "/profiles/max/.credentials.json", max_cache_key}, 1000
    assert default_credentials == UsageApi.default_credentials_path()
    assert default_cache_key == ClaudeAccounts.usage_cache_key(nil)
    assert max_cache_key == ClaudeAccounts.usage_cache_key("/profiles/max")

    assert %{"default" => %{freshness: :fresh}, "max" => %{freshness: :fresh}} =
             UsageReadings.snapshot("claude", ["default", "max"])
  end

  test "probing :all covers every registry provider", ctx do
    outcomes =
      ProviderMeterProbe.observe(
        :all,
        opts(ctx,
          usage_api: FakeUsageApi,
          api_key_fetcher: fn _name -> nil end,
          openai_compat_request_fun: fn _request -> flunk("credential-free batch must not issue a balance request") end
        )
      )

    assert outcomes == [
             %{provider: :codex, observed?: false, reason: nil},
             %{provider: :claude, observed?: false, reason: :usage_unavailable},
             %{provider: :kimi, observed?: false, reason: :session_observation_only},
             %{provider: :deepseek, observed?: false, reason: :disabled},
             %{provider: :openrouter, observed?: false, reason: :missing_api_key},
             %{provider: :muse, observed?: false, reason: :unsupported},
             %{provider: :fake, observed?: false, reason: :unsupported}
           ]
  end

  # A close that blows up must not turn the probe into a crash — the session is
  # being abandoned either way.
  test "a failing session close is contained", ctx do
    assert [%{observed?: false}] = ProviderMeterProbe.observe(:codex, opts(ctx, probe_agent: ExplodingCloseAgent))
  end

  # An unexpected atom return is surfaced verbatim rather than flattened, so a
  # new failure shape from the agent is diagnosable from the outcome alone.
  test "an unexpected start_session return is reported, not read as success", ctx do
    assert [%{observed?: false, reason: :something_unexpected}] =
             ProviderMeterProbe.observe(:codex, opts(ctx, probe_agent: OddReturnAgent))
  end

  # Without an explicit workspace the probe derives one under the configured
  # workspace root; the app-server rejects any cwd outside it.
  #
  # The derived directory must also be created on demand: a path that nothing
  # creates leaves the app-server unable to `cd` into it every probe cycle
  # (#1406). Assert both the location (under the workspace root, via the same
  # repo-namespaced layout real tickets use) and that it exists on disk.
  test "a probe with no explicit workspace derives one under the workspace root and creates it", ctx do
    outcome = ctx |> opts() |> Keyword.delete(:workspace) |> then(&ProviderMeterProbe.observe(:codex, &1))

    assert [%{provider: :codex}] = outcome
    assert_received {:session_started, "usage-probe"}
    assert_received {:session_workspace, workspace}

    expected = Aiur.Workspace.workspace_path_under(Aiur.Config.workspace_root(), "usage-probe")
    assert workspace == expected
    assert String.starts_with?(workspace, Aiur.Config.workspace_root())
    assert File.dir?(workspace)
  end

  defp snapshot(provider, observed_at) do
    %ProviderMeterSnapshot{
      provider: provider,
      backend: :app_server,
      provider_account_generation: "gen-secret-1",
      observed_at: observed_at,
      auth_mode: :subscription,
      freshness: :fresh,
      health: %{state: :healthy, failure: nil, last_observed_at: observed_at, last_source_version: 1},
      windows: %{}
    }
  end
end
