defmodule Aiur.ProviderMeterProbeTest do
  use ExUnit.Case, async: true

  alias Aiur.OpenAICompat.ProviderMeterProbe, as: OpenAICompatProbe
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

  defmodule OddReturnAgent do
    @moduledoc false

    def start_session(_workspace, _opts), do: :something_unexpected
    def stop_session(_session), do: :ok
  end

  setup do
    projection = :"probe_proj_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({ProviderMeterProjection, [name: projection, subscribe?: false]})

    Process.put(:probe_test_pid, self())
    Process.put(:probe_projection, pid)

    %{projection: projection, pid: pid}
  end

  # BalanceBaseline persists beside the workflow file; these tests must never
  # read or write a real one, so every probe opts a throwaway path.
  defp baseline_path do
    dir = Path.join(System.tmp_dir!(), "aiur-probe-baseline-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "balance-baseline.json")
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

  test "a raising session start is contained", ctx do
    Process.put(:probe_start_result, :raise)

    assert [%{observed?: false, reason: :probe_failed}] = ProviderMeterProbe.observe(:codex, opts(ctx))
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
             %{provider: :fake, observed?: false, reason: :unsupported}
           ]
  end

  test "disabled providers without credentials are not probed" do
    assert [%{provider: :deepseek, observed?: false, reason: :disabled}] =
             ProviderMeterProbe.observe(:deepseek,
               api_key_fetcher: fn _env -> nil end,
               openai_compat_request_fun: fn _request ->
                 flunk("a keyless disabled provider must not issue a balance request")
               end
             )
  end

  # A meter read is read-only observation, not dispatch: a backend the operator
  # has not yet enabled must still render its balance so the enable decision is
  # informed. A disabled provider with a configured API key is probed.
  test "disabled providers with credentials are still probed for their meter" do
    parent = self()

    assert [%{provider: :deepseek, observed?: true, reason: nil}] =
             ProviderMeterProbe.observe(:deepseek,
               observed_at: ~U[2026-08-01 12:00:00Z],
               deepseek_in_flight: 0,
               path: baseline_path(),
               api_key_fetcher: fn env ->
                 send(parent, {:credential_requested, env})
                 "secret"
               end,
               openai_compat_request_fun: fn request ->
                 send(parent, {:request, request})
                 {:ok, %{status: 200, body: %{"balance_infos" => [%{"currency" => "USD", "total_balance" => "7.25"}]}}}
               end
             )

    assert_receive {:credential_requested, "DEEPSEEK_API_KEY"}
    assert_receive {:request, %{url: "https://api.deepseek.com/user/balance"}}
  end

  test "DeepSeek probe publishes USD prepaid balance and local concurrency" do
    :ok = Events.subscribe_observed()
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request})

      {:ok,
       %{
         status: 200,
         body: %{
           "is_available" => true,
           "balance_infos" => [
             %{"currency" => "CNY", "total_balance" => "10.00"},
             %{"currency" => "USD", "total_balance" => "7.25"}
           ]
         }
       }}
    end

    assert [%{observed?: true, reason: nil}] =
             ProviderMeterProbe.observe(:deepseek,
               backend_configs: %{"deepseek" => %{"enabled" => true}},
               observed_at: ~U[2026-08-01 12:00:00Z],
               deepseek_in_flight: 5,
               path: baseline_path(),
               api_key_fetcher: fn "DEEPSEEK_API_KEY" -> "secret" end,
               openai_compat_request_fun: request_fun
             )

    assert_receive {:request, request}
    assert request.url == "https://api.deepseek.com/user/balance"
    assert request.headers["authorization"] == "Bearer secret"

    assert_receive {:provider_meter_changed, snapshot}
    assert snapshot.provider == :deepseek
    assert snapshot.backend == :openai_compat
    assert snapshot.provider_account_generation == nil
    assert snapshot.windows["prepaid-balance-usd"].credits.amount == 7.25
    assert snapshot.windows["local-concurrency"].remaining == 2_495
  end

  # A prepaid balance renders an honest spend percentage only once a durable
  # baseline exists. The observation that seeds the baseline has no consumption
  # evidence yet, so it stays dollar-only; the next observation measures
  # `used% = (baseline - remaining) / baseline` against the persisted baseline.
  test "DeepSeek balance attaches a spend percentage once a baseline is seeded" do
    :ok = Events.subscribe_observed()
    path = baseline_path()

    request_fun = fn _request ->
      {:ok, %{status: 200, body: %{"balance_infos" => [%{"currency" => "USD", "total_balance" => "50.00"}]}}}
    end

    assert [%{observed?: true, reason: nil}] =
             ProviderMeterProbe.observe(:deepseek,
               backend_configs: %{},
               observed_at: ~U[2026-08-01 12:00:00Z],
               deepseek_in_flight: 0,
               path: path,
               api_key_fetcher: fn "DEEPSEEK_API_KEY" -> "secret" end,
               openai_compat_request_fun: request_fun
             )

    assert_receive {:provider_meter_changed, seeding}
    refute Map.has_key?(seeding.windows["prepaid-balance-usd"], :used_percent)

    later_request_fun = fn _request ->
      {:ok, %{status: 200, body: %{"balance_infos" => [%{"currency" => "USD", "total_balance" => "49.05"}]}}}
    end

    assert [%{observed?: true, reason: nil}] =
             ProviderMeterProbe.observe(:deepseek,
               backend_configs: %{},
               observed_at: ~U[2026-08-01 12:05:00Z],
               deepseek_in_flight: 0,
               path: path,
               api_key_fetcher: fn "DEEPSEEK_API_KEY" -> "secret" end,
               openai_compat_request_fun: later_request_fun
             )

    assert_receive {:provider_meter_changed, measured}
    assert_in_delta measured.windows["prepaid-balance-usd"].used_percent, 1.9, 0.01
    assert measured.windows["prepaid-balance-usd"].credits.amount == 49.05
  end

  test "a configured initial deposit measures spend from the first observation" do
    :ok = Events.subscribe_observed()
    path = baseline_path()

    request_fun = fn _request ->
      {:ok, %{status: 200, body: %{"balance_infos" => [%{"currency" => "USD", "total_balance" => "80.00"}]}}}
    end

    assert [%{observed?: true, reason: nil}] =
             ProviderMeterProbe.observe(:deepseek,
               backend_configs: %{"deepseek" => %{"balance_baseline" => 100.0}},
               observed_at: ~U[2026-08-01 12:00:00Z],
               deepseek_in_flight: 0,
               path: path,
               api_key_fetcher: fn "DEEPSEEK_API_KEY" -> "secret" end,
               openai_compat_request_fun: request_fun
             )

    assert_receive {:provider_meter_changed, snapshot}
    assert_in_delta snapshot.windows["prepaid-balance-usd"].used_percent, 20.0, 0.01
  end

  # A top-up puts the balance above the recorded baseline, so the raw spend
  # percentage goes negative and the lower clamp engages. That clamp used to
  # hand an integer to `Float.round/2`, which raised into the probe's rescue and
  # reported `:probe_failed` — the whole provider then rendered "Unavailable"
  # while its API was answering perfectly.
  test "a balance topped up above the baseline reads 0% instead of failing the probe" do
    :ok = Events.subscribe_observed()

    assert [%{observed?: true, reason: nil}] =
             ProviderMeterProbe.observe(:deepseek,
               backend_configs: %{"deepseek" => %{"balance_baseline" => 1.43}},
               observed_at: ~U[2026-08-01 12:00:00Z],
               deepseek_in_flight: 0,
               path: baseline_path(),
               api_key_fetcher: fn "DEEPSEEK_API_KEY" -> "secret" end,
               openai_compat_request_fun: fn _request ->
                 {:ok, %{status: 200, body: %{"balance_infos" => [%{"currency" => "USD", "total_balance" => "8.55"}]}}}
               end
             )

    assert_receive {:provider_meter_changed, snapshot}
    assert snapshot.windows["prepaid-balance-usd"].used_percent == 0.0
    assert snapshot.windows["prepaid-balance-usd"].credits.amount == 8.55
  end

  # The companion bound, pinned rather than regressed: an emptied account is the
  # only way to reach the upper clamp (`balance >= 0` caps the raw percentage at
  # 100), and this asserts it still lands on a rounded float. Widening the clamp
  # inputs must not turn the cap into an integer the way the lower bound did.
  test "an exhausted balance reads 100% as a float" do
    :ok = Events.subscribe_observed()

    assert [%{observed?: true, reason: nil}] =
             ProviderMeterProbe.observe(:deepseek,
               backend_configs: %{"deepseek" => %{"balance_baseline" => 40.0}},
               observed_at: ~U[2026-08-01 12:00:00Z],
               deepseek_in_flight: 0,
               path: baseline_path(),
               api_key_fetcher: fn "DEEPSEEK_API_KEY" -> "secret" end,
               openai_compat_request_fun: fn _request ->
                 {:ok, %{status: 200, body: %{"balance_infos" => [%{"currency" => "USD", "total_balance" => "0.00"}]}}}
               end
             )

    assert_receive {:provider_meter_changed, snapshot}
    assert snapshot.windows["prepaid-balance-usd"].used_percent == 100.0
    assert snapshot.windows["prepaid-balance-usd"].credits.status == :exhausted
  end

  test "OpenRouter probe uses the management key and subtracts usage from credits" do
    :ok = Events.subscribe_observed()
    parent = self()

    assert %{observed?: true} =
             OpenAICompatProbe.probe(:openrouter, "openrouter",
               observed_at: ~U[2026-08-01 12:00:00Z],
               path: baseline_path(),
               api_key_fetcher: fn env ->
                 send(parent, {:key_env, env})
                 "management-secret"
               end,
               openai_compat_request_fun: fn request ->
                 send(parent, {:request, request})
                 {:ok, %{status: 200, body: %{"data" => %{"total_credits" => 100, "total_usage" => 22.5}}}}
               end
             )

    assert_receive {:key_env, "OPENROUTER_MANAGEMENT_KEY"}
    assert_receive {:request, %{url: "https://openrouter.ai/api/v1/credits"}}
    assert_receive {:provider_meter_changed, snapshot}
    assert snapshot.windows["credits-remaining"].credits.amount == 77.5
  end

  # A baseline write that fails (read-only mount, full disk, an un-creatable
  # directory) must never take down the balance probe: the balance still
  # publishes dollar-only, with no spend percentage. This is the regression the
  # probe used to turn into a hard `:probe_failed` — the `File.mkdir_p!/1` in
  # `BalanceBaseline.write/2` sat outside its guard and raised through
  # `resolve/3`.
  test "DeepSeek publishes a balance window even when the baseline cannot be written" do
    :ok = Events.subscribe_observed()

    file = Path.join(System.tmp_dir!(), "aiur-probe-mkdirfail-#{System.unique_integer([:positive])}")
    File.write!(file, "not a directory")
    on_exit(fn -> File.rm(file) end)
    path = Path.join([file, "sub", "balance-baseline.json"])

    assert %{observed?: true, reason: nil} =
             OpenAICompatProbe.probe(:deepseek, "deepseek",
               backend_configs: %{},
               observed_at: ~U[2026-08-01 12:00:00Z],
               deepseek_in_flight: 0,
               path: path,
               api_key_fetcher: fn "DEEPSEEK_API_KEY" -> "secret" end,
               openai_compat_request_fun: fn _request ->
                 {:ok, %{status: 200, body: %{"balance_infos" => [%{"currency" => "USD", "total_balance" => "16.85"}]}}}
               end
             )

    assert_receive {:provider_meter_changed, snapshot}
    assert snapshot.windows["prepaid-balance-usd"].credits.amount == 16.85
    refute Map.has_key?(snapshot.windows["prepaid-balance-usd"], :used_percent)
  end

  test "absent or malformed balance values never fabricate zero credits" do
    :ok = Events.subscribe_observed()

    assert %{observed?: false, reason: :missing_api_key} =
             OpenAICompatProbe.probe(:deepseek, "deepseek", path: baseline_path(), api_key_fetcher: fn _ -> nil end)

    assert %{observed?: false, reason: :malformed} =
             OpenAICompatProbe.probe(:openrouter, "openrouter",
               path: baseline_path(),
               api_key_fetcher: fn _ -> "secret" end,
               openai_compat_request_fun: fn _ -> {:ok, %{status: 200, body: %{"data" => %{}}}} end
             )

    refute_receive {:provider_meter_changed, _snapshot}
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
