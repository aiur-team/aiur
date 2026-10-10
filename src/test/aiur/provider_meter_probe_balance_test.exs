defmodule Aiur.ProviderMeterProbeBalanceTest do
  # These tests subscribe to shared provider-meter topics, so running alongside
  # other publisher cases lets foreign snapshots satisfy their receive checks.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Accounts.UsageReadings
  alias Aiur.OpenAICompat.BalanceBaseline
  alias Aiur.OpenAICompat.ProviderMeterProbe, as: OpenAICompatProbe
  alias Aiur.ProviderMeterProbe
  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeters.Events

  setup do
    UsageReadings.reset()
    on_exit(&UsageReadings.reset/0)
    projection = :"probe_proj_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({ProviderMeterProjection, [name: projection, subscribe?: false]})

    Process.put(:probe_test_pid, self())
    Process.put(:probe_projection, pid)

    %{projection: projection, pid: pid}
  end

  # BalanceBaseline persists beside the workflow file; these tests must never
  # read or write a real one, so every probe opts a throwaway path.
  defp baseline_path do
    dir = Aiur.TestSupport.tmp_root!("aiur-probe-baseline")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "balance-baseline.json")
  end

  test "disabled providers without credentials are not probed" do
    assert [%{provider: :deepseek, observed?: false, reason: :disabled}] =
             ProviderMeterProbe.observe(:deepseek,
               # Pinned for the same reason `opts/2` pins it: read live, the
               # dispatch gate answers from whatever config the daemon (or a
               # neighbouring suite) has loaded, and "deepseek is not enabled"
               # is precisely the premise under test.
               backend_configs: %{},
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

    assert_receive {:credential_requested, "DEEPSEEK_API_KEY"}, 1000
    assert_receive {:request, %{url: "https://api.deepseek.com/user/balance"}}, 1000
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

    assert_receive {:request, request}, 1000
    assert request.url == "https://api.deepseek.com/user/balance"
    assert request.headers["authorization"] == "Bearer secret"

    assert_receive {:provider_meter_changed, snapshot}, 1000
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

    assert_receive {:provider_meter_changed, seeding}, 1000
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

    assert_receive {:provider_meter_changed, measured}, 1000
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

    assert_receive {:provider_meter_changed, snapshot}, 1000
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

    assert_receive {:provider_meter_changed, snapshot}, 1000
    assert snapshot.windows["prepaid-balance-usd"].used_percent == 0.0
    assert snapshot.windows["prepaid-balance-usd"].credits.amount == 8.55
  end

  # Not crashing was only half the fix. A baseline stranded below the observed
  # balance then reported 0% spent against a much larger balance — technically
  # true, useless in practice — and clearing it meant an operator deleting a
  # JSON file by hand. The probe re-anchors itself instead.
  test "a top-up above the persisted baseline reseeds it and resumes measuring spend" do
    :ok = Events.subscribe_observed()
    path = baseline_path()

    balance_fun = fn amount ->
      fn _request -> {:ok, %{status: 200, body: %{"balance_infos" => [%{"currency" => "USD", "total_balance" => amount}]}}} end
    end

    probe = fn amount, observed_at ->
      assert [%{observed?: true, reason: nil}] =
               ProviderMeterProbe.observe(:deepseek,
                 backend_configs: %{},
                 observed_at: observed_at,
                 deepseek_in_flight: 0,
                 path: path,
                 api_key_fetcher: fn "DEEPSEEK_API_KEY" -> "secret" end,
                 openai_compat_request_fun: balance_fun.(amount)
               )

      assert_receive {:provider_meter_changed, snapshot}, 1000
      snapshot.windows["prepaid-balance-usd"]
    end

    _seeding = probe.("1.43", ~U[2026-08-12 05:12:52Z])

    # The top-up. Nothing has been spent against the new anchor yet, so the
    # window is dollar-only rather than a fabricated 0%.
    topped_up = probe.("8.55", ~U[2026-08-15 17:28:04Z])
    refute Map.has_key?(topped_up, :used_percent)
    assert topped_up.credits.amount == 8.55

    assert BalanceBaseline.persisted_baseline(:deepseek, path) == 8.55

    # And the next observation measures spend against the reseeded baseline —
    # no operator ever touched the ledger.
    spent = probe.("6.84", ~U[2026-08-15 17:33:04Z])
    assert_in_delta spent.used_percent, 20.0, 0.01
  end

  # The blanket rescue that contains a probe crash used to flatten it onto
  # `:probe_failed`, the same reason a provider that never answered reports.
  # That is exactly why a one-line type error read as a multi-day outage, so
  # "we raised" now carries its own reason and its own log line.
  test "an adapter that raises reports :probe_crashed, not a provider outage" do
    log =
      capture_log(fn ->
        assert %{observed?: false, reason: :probe_crashed} =
                 OpenAICompatProbe.probe(:deepseek, "deepseek",
                   backend_configs: %{},
                   observed_at: ~U[2026-08-01 12:00:00Z],
                   deepseek_in_flight: 0,
                   path: baseline_path(),
                   api_key_fetcher: fn "DEEPSEEK_API_KEY" -> "secret" end,
                   openai_compat_request_fun: fn _request -> raise ArgumentError, "errors were found at the given arguments" end
                 )
      end)

    assert log =~ "provider meter probe crashed"
    assert log =~ "provider=:deepseek"
    assert log =~ "ArgumentError"
  end

  # A provider that genuinely does not answer keeps the distinct, unchanged
  # reason. The point of the split is that the two are told apart, not that
  # everything became a crash.
  test "a provider that does not answer keeps its own transport reason" do
    assert %{observed?: false, reason: :transport} =
             OpenAICompatProbe.probe(:deepseek, "deepseek",
               backend_configs: %{},
               observed_at: ~U[2026-08-01 12:00:00Z],
               deepseek_in_flight: 0,
               path: baseline_path(),
               api_key_fetcher: fn "DEEPSEEK_API_KEY" -> "secret" end,
               openai_compat_request_fun: fn _request -> {:error, :transport} end
             )
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

    assert_receive {:provider_meter_changed, snapshot}, 1000
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

    assert_receive {:key_env, "OPENROUTER_MANAGEMENT_KEY"}, 1000
    assert_receive {:request, %{url: "https://openrouter.ai/api/v1/credits"}}, 1000
    assert_receive {:provider_meter_changed, snapshot}, 1000
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

    file = Aiur.TestSupport.tmp_root!("aiur-probe-mkdirfail")
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

    assert_receive {:provider_meter_changed, snapshot}, 1000
    assert snapshot.windows["prepaid-balance-usd"].credits.amount == 16.85
    refute Map.has_key?(snapshot.windows["prepaid-balance-usd"], :used_percent)
  end

  test "absent or malformed balance values never fabricate zero credits" do
    test_pid = self()
    broadcast_ref = make_ref()
    broadcast = fn snapshot -> send(test_pid, {broadcast_ref, snapshot}) end

    assert %{observed?: false, reason: :missing_api_key} =
             OpenAICompatProbe.probe(:deepseek, "deepseek",
               path: baseline_path(),
               provider_meter_broadcast_fun: broadcast,
               api_key_fetcher: fn _ -> nil end
             )

    assert %{observed?: false, reason: :malformed} =
             OpenAICompatProbe.probe(:openrouter, "openrouter",
               path: baseline_path(),
               provider_meter_broadcast_fun: broadcast,
               api_key_fetcher: fn _ -> "secret" end,
               openai_compat_request_fun: fn _ -> {:ok, %{status: 200, body: %{"data" => %{}}}} end
             )

    refute_received {^broadcast_ref, _snapshot}
  end
end
