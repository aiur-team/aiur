defmodule AiurWeb.Build.UsageTest do
  use ExUnit.Case, async: true
  alias Aiur.ProviderMeterSnapshot
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias AiurWeb.Build.{Payload, Read, Usage}
  defp block(inputs) do
    usage = Usage.block({:ok, nil}, inputs, I.now())
    fixture = File.read!(Path.expand("../../fixtures/build_home/live.json", __DIR__)) |> Jason.decode!()
    assert Payload.validate(Map.put(fixture, "usage", Payload.scrub(usage))) == :ok
    usage
  end

  defp provider(windows, overrides \\ %{}, family \\ :codex) do
    inputs = I.inputs(%{families: [family], meters: %{family => I.snapshot(family, windows, overrides)}})
    block(inputs).providers |> hd()
  end

  test "U1 U2 U3 U13 windows classify by duration and keep unknown distinct from zero" do
    row = provider(%{"x:short" => I.window(42, 300), "x:long" => I.window(61, 10_080)})
    assert row.session == %{acc: [42], win: "5h", reset_at: Usage.ms(DateTime.add(I.now(), 3600))}
    assert row.weekly.acc == [61]
    assert row.weekly.win == "7d"
    unknown = provider(%{"x:other" => I.window(nil, nil, %{coverage: :empty_supported})})
    assert unknown.session.acc == [nil]
    assert unknown.session.win == nil
    assert Jason.encode!(unknown.session) =~ "\"acc\":[null]"
    assert provider(%{"primary" => I.window(0)}).session.acc == [0]
  end

  test "U4 unavailable identities retain distinct causes and no windows" do
    unknown = ProviderMeterSnapshot.unknown(:codex, :app_server)
    signed_out = I.snapshot(:codex, %{}, %{health: %{state: :unavailable, failure: :no_oauth_token}})
    error = I.snapshot(:codex, %{}, %{health: %{state: :stale, failure: :transport}})

    for {snapshot, note} <- [{nil, "Awaiting first observation"}, {unknown, "Awaiting first observation"}, {signed_out, "Not signed in"}, {error, "Transport error"}] do
      row = block(I.inputs(%{meters: %{codex: snapshot}})).providers |> hd()
      assert row.none
      assert row.note == note
      assert row.session == nil
      assert row.weekly == nil
    end
  end

  test "U5 U14 stale cards and ended windows retain values with timestamp" do
    row = provider(%{"primary" => I.window(42)}, %{health: %{state: :stale, failure: :transport}})
    assert row.stale
    assert row.session.acc == [42]
    assert row.observed_at == Usage.ms(I.now())
    ended = provider(%{"primary" => I.window(42, 300, %{resets_at: DateTime.add(I.now(), -60)})})
    assert ended.stale
  end

  test "U6 durable standing applies only to unknown identity" do
    durable = %{codex: %{percent: 100, observed_at: I.now()}}
    unknown = ProviderMeterSnapshot.unknown(:codex, :app_server)
    row = block(I.inputs(%{meters: %{codex: unknown}, durable: durable})).providers |> hd()
    assert row.none and row.stale
    assert row.note == "Last known 100% (previous boot)"
    assert row.observed_at == Usage.ms(I.now())
    loading = block(I.inputs(%{durable: durable})).providers |> hd()
    assert loading.note == "Awaiting first observation"
    refute loading.stale
  end

  test "U7 credits require an observed baseline and format float balance" do
    credit = I.window(nil, nil, %{kind: :credit, credits: %{status: :available, amount: 10.4}, remaining: 10.4})
    row = provider(%{"balance" => credit}, %{}, :deepseek)
    assert row.credits == %{pct: nil, left: "$10.40", tip: [["Prepaid credits", "$10.40 left"]]}
    assert provider(%{"balance" => %{credit | used_percent: 2.0}}, %{}, :deepseek).credits.pct == 2
    assert provider(%{"balance" => credit}).credits == nil
    mixed = provider(%{"balance" => credit, "primary" => I.window(9)}, %{}, :deepseek)
    assert mixed.credits == nil
    assert mixed.session.acc == [9]
  end

  test "U8 U9 accounts align sorted slots and preserve failed readings" do
    snapshot = I.snapshot(:claude, %{"primary" => I.window(40), "secondary" => I.window(50)})
    accounts = %{"work" => I.account(1, 96), "personal" => %{reading: nil, observed_at: I.now()}}
    inputs = I.inputs(%{families: [:claude], meters: %{claude: snapshot}, accounts: accounts})
    row = block(inputs).providers |> hd()
    assert row.accounts == ["personal", "work"]
    assert row.session.acc == [nil, 1]
    assert row.weekly.acc == [nil, 96]
    assert row.session.reset_at == Usage.ms(DateTime.add(I.now(), 3600))
    single = block(%{inputs | accounts: Map.take(accounts, ["work"])}).providers |> hd()
    assert single.accounts == nil
    assert single.session.acc == [40]
  end

  test "U10 U12 unknown logos use mono letter and design providers lead registry extras" do
    row = provider(%{"primary" => I.window(5)}, %{}, :muse)
    assert row.logo == nil
    assert row.mono == "M"
    assert row.hue == nil
    assert Usage.order_families([:codex, :claude, :deepseek, :kimi, :muse]) == [:claude, :codex, :kimi, :deepseek, :muse]
  end

  test "G1 budgets use core requests and gql points with integer percent" do
    row = block(I.inputs(%{github: {:ok, I.quota()}})).apis |> hd()
    assert row.icon == "github"

    assert row.lines == [
             %{tag: "core", acc: [5], reset_at: Usage.ms(DateTime.add(I.now(), 3600)), win: "1h", tip: [["Requests left", "4,736 of 5,000"]], hold_until: nil},
             %{tag: "gql", acc: [0], reset_at: Usage.ms(DateTime.add(I.now(), 3600)), win: "1h", tip: [["Points left", "4,998 of 5,000"]], hold_until: nil}
           ]
  end

  test "G2 G3 unknown and unavailable meters remain distinct" do
    for {github, note} <- [{I.inputs().github, "not observed yet"}, {{:error, :unavailable}, "GitHub budget meter unavailable"}] do
      row = block(I.inputs(%{github: github})).apis |> hd()
      assert hd(row.lines).acc == [nil]
      assert hd(row.lines).reset_at == nil
      assert hd(row.lines).tip == [["Requests left", note]]
    end
  end

  test "G4 G5 floor and resource backoff hold until the later active deadline" do
    quota = I.quota(400)
    later = DateTime.add(I.now(), 7200)
    quota = %{quota | backoffs: [%{resource: "core", until: later}, %{resource: "graphql", until: later}]}
    [core, gql] = hd(block(I.inputs(%{github: {:ok, quota}})).apis).lines
    assert core.hold_until == Usage.ms(later)
    assert gql.hold_until == Usage.ms(later)
    assert length(core.tip) == 1
    no_backoff = %{quota | backoffs: []}
    assert hd(hd(block(I.inputs(%{github: {:ok, no_backoff}})).apis).lines).hold_until == Usage.ms(DateTime.add(I.now(), 3600))
    assert hd(hd(block(I.inputs(%{github: {:ok, I.quota(600)}})).apis).lines).hold_until == nil
  end

  test "E1 E2 ElevenLabs configured states and no synthetic Search" do
    assert length(block(I.inputs()).apis) == 1

    for {state, note} <- [{:unknown, "not observed yet"}, {:failed, "the API key was rejected"}] do
      [_, row] = block(I.inputs(%{elevenlabs: %{state: state, failure: :authentication}})).apis
      assert row.name == "ElevenLabs"
      assert hd(row.lines).acc == [nil]
      assert hd(row.lines).tip == [["Credits left", note]]
    end

    window = %{used_percent: 10.0, remaining: 90_000, reset_at: DateTime.add(I.now(), 3600)}
    rows = block(I.inputs(%{elevenlabs: %{state: :observed, window: window}})).apis
    assert hd(List.last(rows).lines).tip == [["Credits left", "90.0K"]]
    refute Enum.any?(rows, &(&1.name == "Search"))
  end

  test "L1 locked calls short circuit all reads and subscriptions" do
    assert Usage.read(:locked, meter_source: __MODULE__) == Read.locked_usage()
    assert Usage.subscribe(:locked) == :ok
    assert Map.keys(Usage.read(:locked)) |> Enum.sort() == ~w(accessible_name authentication_path reason state)
    assert Usage.block({:ok, nil}, :error, I.now()).reason == "usage_source_failed"
  end

  test "L2 P1 real facts match frozen PSETS4 values and pass payload validation" do
    usage = block(I.psets4())
    fixture = File.read!(Path.expand("../../fixtures/build_home/live.json", __DIR__)) |> Jason.decode!()
    assert Enum.map(usage.providers, & &1.name) == Enum.map(fixture["usage"]["providers"], & &1["name"])

    for {row, expected} <- Enum.zip(usage.providers, fixture["usage"]["providers"]) do
      for key <- [:name, :logo, :accounts], do: assert(Map.fetch!(row, key) == expected[Atom.to_string(key)])

      for key <- [:session, :weekly], row[key] != nil do
        assert row[key].acc == expected[Atom.to_string(key)]["acc"]
        assert row[key].win == expected[Atom.to_string(key)]["win"]
      end

      if row.credits do
        assert row.credits.pct == expected["credits"]["pct"]
        assert row.credits.left == expected["credits"]["left"]
      end
    end

    assert Payload.validate(Map.put(fixture, "usage", Payload.scrub(usage))) == :ok
    assert Payload.validate(Map.put(fixture, "usage", Usage.read(:locked))) == :ok
    assert Payload.validate(Map.put(fixture, "usage", Payload.scrub(Usage.block({:ok, nil}, :error, nil)))) == :ok
    encoded = Jason.encode!(usage)
    refute encoded =~ "private-generation"
    refute encoded =~ "auth_mode"
  end
end
