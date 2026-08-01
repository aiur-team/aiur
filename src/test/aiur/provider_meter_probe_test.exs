defmodule Aiur.ProviderMeterProbeTest do
  use ExUnit.Case, async: true

  alias Aiur.{ProviderMeterProbe, ProviderMeterProjection, ProviderMeterSnapshot}

  defmodule FakeAgent do
    @moduledoc false

    def start_session(workspace, opts) do
      case Process.get(:probe_start_result, :ok) do
        :ok ->
          send(Process.get(:probe_test_pid), {:session_started, Keyword.get(opts, :identifier)})
          send(Process.get(:probe_test_pid), {:session_workspace, workspace})
          {:ok, %{fake: true}}

        {:error, _reason} = error ->
          error

        :raise ->
          raise "app-server unavailable"
      end
    end

    def stop_session(session) do
      send(Process.get(:probe_test_pid), {:session_stopped, session})
      :ok
    end
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

    %{projection: projection, pid: pid}
  end

  defp opts(ctx, extra \\ []) do
    Keyword.merge(
      [
        projection: ctx.projection,
        workspace: "/tmp/aiur-probe-test",
        observation_window_ms: 60,
        probe_agent: FakeAgent
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
    task =
      Task.async(fn ->
        Process.sleep(20)
        send(ctx.pid, {:provider_meter_changed, snapshot(:codex)})
      end)

    [outcome] = ProviderMeterProbe.observe(:codex, opts(ctx, observation_window_ms: 2_000))
    Task.await(task)

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
    outcomes = ProviderMeterProbe.observe(:all, opts(ctx))

    assert Enum.map(outcomes, & &1.provider) == [:codex, :claude, :fake]
    assert List.last(outcomes) == %{provider: :fake, observed?: false, reason: :unsupported}
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

  defp snapshot(provider) do
    observed_at = DateTime.utc_now()

    %ProviderMeterSnapshot{
      provider: provider,
      backend: :app_server,
      provider_account_generation: "gen-1",
      observed_at: observed_at,
      auth_mode: :subscription,
      freshness: :fresh,
      health: %{state: :healthy, failure: nil, last_observed_at: observed_at, last_source_version: 1},
      windows: %{"session" => %{kind: :rate_limit, used_percent: 10}}
    }
  end
end
