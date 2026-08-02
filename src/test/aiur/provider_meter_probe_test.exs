defmodule Aiur.ProviderMeterProbeTest do
  use ExUnit.Case, async: true

  alias Aiur.{ProviderMeterProbe, ProviderMeterProjection, ProviderMeterSnapshot}
  alias Aiur.OpenAICompat.ProviderMeterProbe, as: OpenAICompatProbe
  alias Aiur.ProviderMeters.Events

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

  test "disabled providers are not probed even when their credentials exist" do
    parent = self()

    assert [%{provider: :deepseek, observed?: false, reason: :disabled}] =
             ProviderMeterProbe.observe(:deepseek,
               api_key_fetcher: fn env ->
                 send(parent, {:credential_requested, env})
                 "secret"
               end
             )

    refute_receive {:credential_requested, _env}
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

  test "OpenRouter probe uses the management key and subtracts usage from credits" do
    :ok = Events.subscribe_observed()
    parent = self()

    assert %{observed?: true} =
             OpenAICompatProbe.probe(:openrouter, "openrouter",
               observed_at: ~U[2026-08-01 12:00:00Z],
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

  test "absent or malformed balance values never fabricate zero credits" do
    :ok = Events.subscribe_observed()

    assert %{observed?: false, reason: :missing_api_key} =
             OpenAICompatProbe.probe(:deepseek, "deepseek", api_key_fetcher: fn _ -> nil end)

    assert %{observed?: false, reason: :malformed} =
             OpenAICompatProbe.probe(:openrouter, "openrouter",
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
end
