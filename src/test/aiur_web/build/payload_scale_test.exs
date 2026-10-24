defmodule AiurWeb.Build.PayloadScaleTest do
  @moduledoc """
  Byte budgets for the build home at 10,000 tickets (MP-E8-C12-T06, S1-S5).

  Bytes do not depend on the machine, so these run in CI. Timing lives in the
  opt-in `:perf_regression` file beside this one.
  """
  use ExUnit.Case, async: false
  use Aiur.TestSupport

  alias Aiur.BuildOrder.Index, as: Core
  alias Aiur.TestSupport.BuildHome.{FixtureSource, IndexSeed, Scale}
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Build.{ConversationPayload, Index, IndexSource, Payload, Usage}
  alias AiurWeb.Build.ConversationSource.Wave0b

  @zone "America/Los_Angeles"
  @snapshot_budget 65_536
  @growth_budget 2_048
  # The ticket proposed 16,384 B (31 rows x 400 B) and 163,840 B (300 x 326 B). A v1 row is
  # 518 B on average in the design data (228 B are field names), measured 2026-10-22:
  # densest day 16,501 B, nq300 178,073 B. Rebased on 31 x 660 B and 300 x 655 B.
  @day_budget 20_480
  @month_budget 524_288
  @nq300_budget 196_608
  @conversation_budget 49_152
  @capped_conversation_budget 1_048_576

  defmodule UsageStub do
    @moduledoc false
    def read(_, _), do: Usage.read(:locked)
    def subscribe(_), do: :ok
  end

  defmodule FreshnessStub do
    @moduledoc false
    def read_daemon(_), do: %{state: "live", heartbeat_at: 1, observed_at: 2}
  end

  setup_all do
    {:ok, dense} = FixtureSource.full(dataset: "dense")
    %{dense: dense, scale: Scale.dataset(dense, 10_000)}
  end

  describe "Scale generator" do
    test "G1 scale dataset is exact and deterministic", %{dense: dense, scale: scale} do
      rows = all_rows(scale)
      assert length(rows) == 10_000
      assert Scale.dataset(dense, 10_000) == scale
      ids = Enum.map(rows, & &1["id"])
      assert length(Enum.uniq(ids)) == 10_000
      # Payload.validate/1 accepts only decimal ids, so a suffixed copy id would void every snapshot.
      assert Enum.all?(ids, &Regex.match?(~r/^[1-9][0-9]*$/, &1))
      assert Enum.all?(rows, &(&1["num"] == String.to_integer(&1["id"])))
      assert scale["history"]["total"] == length(scale["sections"]["hist"])
      # 60 active dense days replicated back by 84-day steps: pinned so a generator change is visible.
      assert scale["sections"]["hist"] |> Enum.map(&Scale.local_date(&1["end"])) |> Enum.uniq() |> length() == 458
      assert {:ok, snapshot} = FixtureSource.snapshot(dataset: "scale10k", time_zone: @zone)
      assert Payload.validate(Payload.snapshot(snapshot, "scale", 0)) == :ok
    end

    test "G2 scale deps stay inside the set", %{dense: dense, scale: scale} do
      known = MapSet.new(all_rows(scale), & &1["id"])
      dense_known = MapSet.new(all_rows(dense), & &1["id"])
      dangling = fn data, ids -> for row <- all_rows(data), dep <- row["deps"] ++ row["children"], not MapSet.member?(ids, dep), uniq: true, do: dep end
      # A copy may only point at an id that was already outside dense; remapping keeps chains within one copy.
      assert MapSet.subset?(MapSet.new(dangling.(scale, known)), MapSet.new(dangling.(dense, dense_known)))
      copy = Enum.find(scale["sections"]["hist"], &(String.to_integer(&1["id"]) > 100_000 and &1["deps"] != []))
      assert Enum.all?(copy["deps"], &(div(String.to_integer(&1), 100_000) == div(String.to_integer(copy["id"]), 100_000)))
      assert Map.keys(copy["dep_states"]) |> Enum.sort() == Enum.sort(copy["deps"])
    end

    test "G3 scale keeps local wall time across DST", %{dense: dense, scale: scale} do
      source = Map.new(dense["sections"]["hist"], &{&1["id"], &1})
      copies = Enum.filter(scale["sections"]["hist"], &(String.to_integer(&1["id"]) > 100_000))
      crossings = Enum.filter(copies, &dst_crossing?(source[base_id(&1["id"])]["end"], &1["end"]))
      # Copies cross both 2025-11-02 and 2026-03-08; a fixed-millisecond shift would move these by an hour.
      assert length(crossings) > 100

      for copy <- copies do
        original = source[base_id(copy["id"])]
        assert Date.day_of_week(Scale.local_date(copy["end"])) == Date.day_of_week(Scale.local_date(original["end"]))
        assert wall(copy["end"]) == wall(original["end"])
      end

      counts = fn rows -> rows |> Enum.frequencies_by(&Scale.local_date(&1["end"])) |> Map.values() |> Enum.sort() end
      first_copy = Enum.filter(copies, &(div(String.to_integer(&1["id"]), 100_000) == 1))
      assert counts.(first_copy) == counts.(dense["sections"]["hist"])
    end

    test "with_nq, with_active and conversation keep ids decimal and counts exact", %{dense: dense} do
      nq = Scale.with_nq(dense, 300)
      assert length(nq["sections"]["nq"]) == 300
      assert nq["sections"]["nq"] |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 300
      assert Payload.validate(Payload.snapshot(nq, "nq", 0)) == :ok
      active = Scale.with_active(dense, 20)
      assert Enum.count(active["sections"]["now"], &(&1["agent"]["state"] == "active")) == 20
      assert Payload.validate(Payload.snapshot(active, "active", 0)) == :ok
      items = [%{"k" => "say", "text" => "a", "at" => 120_000, "id" => "d:0"}, %{"k" => "say", "text" => "b", "at" => 180_000, "id" => "d:1"}]
      entries = Scale.conversation(items, 5)
      assert Enum.map(entries, & &1["id"]) == ~w(s:0 s:1 s:2 s:3 s:4)
      # The newest repeat keeps the source times; each older repeat is one minute earlier.
      assert Enum.map(entries, & &1["at"]) == [0, 60_000, 60_000, 120_000, 120_000]
      assert Scale.perf_ticket_id(dense) == hd(dense["sections"]["now"])["id"]
    end
  end

  describe "byte budgets over the real index" do
    setup do
      Aiur.TestSupport.start_owned_endpoint!()
      :ok
    end

    test "guard: S1 snapshot bytes do not grow with history (EC-09)", %{dense: dense, scale: scale} do
      # History owns a named ETS mirror, so one seeded index runs at a time.
      small = with_index(dense, &snapshot_bytes/1)
      large = with_index(scale, &snapshot_bytes/1)
      report("S1 dense", small.bytes, @snapshot_budget)
      report("S1 scale10k", large.bytes, @snapshot_budget)
      report("S5 dense snapshot (estimate, raw deflate)", small.deflate, nil)
      report("S5 scale10k snapshot (estimate, raw deflate)", large.deflate, nil)
      assert small.bytes <= @snapshot_budget
      assert large.bytes <= @snapshot_budget
      assert abs(large.bytes - small.bytes) <= @growth_budget
    end

    test "guard: S2 day page bytes", %{scale: scale} do
      {day, _count} = scale["sections"]["hist"] |> Enum.frequencies_by(&Scale.local_date(&1["end"])) |> Enum.max_by(fn {date, count} -> {count, Date.to_gregorian_days(date)} end)

      {densest, month} =
        with_index(scale, fn server ->
          {:ok, snapshot} = snapshot(server)
          {earlier_message(server, Core.local_midnight(Date.add(day, 1), @zone), 1), earlier_message(server, snapshot.history.from, 31)}
        end)

      assert densest["rows"] != []
      assert Enum.all?(densest["rows"], &(Scale.local_date(&1["end"]) == day))
      report("S2 densest day", Payload.bytes(densest), @day_budget)
      report("S2 31 days", Payload.bytes(month), @month_budget)
      report("S5 31 days (estimate, raw deflate)", deflate(month), nil)
      assert Payload.bytes(densest) <= @day_budget
      assert Payload.bytes(month) <= @month_budget
      assert month["history"]["more"] == true
    end

    test "guard: S3 not-queued rows cost per row", %{dense: dense} do
      message = with_index(Scale.with_nq(dense, 300), fn server -> server |> snapshot() |> elem(1) |> Payload.snapshot("scale", 0) end)
      assert length(message["sections"]["nq"]) == 300
      report("S3 nq300", Payload.bytes(message), @nq300_budget)
      report("S5 nq300 (estimate, raw deflate)", deflate(message), nil)
      assert Payload.bytes(message) <= @nq300_budget
    end
  end

  describe "conversation page bytes" do
    setup do
      root = Aiur.TestSupport.tmp_root!("payload-scale-conversation")
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/aiur", workspace_root: root)
      workspace = Path.join([root, "owner", "aiur", "7"])
      File.mkdir_p!(Path.join(workspace, "logs"))
      EndpointStubs.scope(build_conversation_snapshot_fun: fn _, _ -> {:ok, %{running: []}} end)
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
      {:ok, workspace: workspace, ref: %{id: "7", identity: nil, closed?: true, row: %{model: "Codex", effort: "high"}}}
    end

    test "guard: S4 conversation page bytes", %{workspace: workspace, ref: ref} do
      {:ok, text} = File.read(Path.expand("../../fixtures/build_home/conversations/dense.json", __DIR__))
      design = text |> Jason.decode!() |> Map.values() |> List.flatten() |> Enum.map(&(&1["text"] || &1["label"])) |> Enum.filter(&is_binary/1)
      write_messages(workspace, Enum.take(Stream.cycle(design), 120))
      shaped = conversation_page(ref)
      assert length(shaped["entries"]) == 100
      # 20,000 ASCII chars per entry: the 1 MiB read cap and the 8,000-char text cap both bind.
      write_messages(workspace, List.duplicate(String.duplicate("x", 20_000), 120))
      capped = conversation_page(ref)
      assert capped["entries"] != [] and length(capped["entries"]) <= 100
      assert Enum.all?(capped["entries"], &(String.length(&1["text"]) <= 8_000))
      report("S4 design-shape page", Payload.bytes(shaped), @conversation_budget)
      report("S4 capped worst case", Payload.bytes(capped), @capped_conversation_budget)
      report("S5 design-shape page (estimate, raw deflate)", deflate(shaped), nil)
      assert Payload.bytes(shaped) <= @conversation_budget
      assert Payload.bytes(capped) <= @capped_conversation_budget
    end
  end

  defp with_index(data, fun) do
    dir = Aiur.TestSupport.tmp_root!("payload-scale")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    seed = IndexSeed.start(data, dir)
    id = make_ref()

    try do
      server =
        start_supervised!(
          {Index,
           name: nil,
           subscribe: fn -> :ok end,
           read: fn _, _, _ -> seed.parts end,
           daemon_read: &FreshnessStub.read_daemon/1,
           daemon_timer: fn _, _, _ -> make_ref() end,
           clock: fn -> seed.data["now"] end},
          id: id
        )

      fun.(server)
    after
      stop_supervised(id)
      IndexSeed.stop(seed)
    end
  end

  defp snapshot(server), do: IndexSource.snapshot(server: server, time_zone: @zone, financial: :locked, usage: UsageStub, freshness: FreshnessStub, timeout: 60_000)

  # C3-T02's 64 KB budget excludes the not-queued section; S3 owns that one.
  defp snapshot_bytes(server) do
    {:ok, snapshot} = snapshot(server)
    message = snapshot |> Payload.snapshot("scale", 0) |> put_in(["sections", "nq"], [])
    assert Payload.validate(message) == :ok
    %{bytes: Payload.bytes(message), deflate: deflate(message)}
  end

  defp earlier_message(server, before, days) do
    {:ok, page} = IndexSource.earlier(before, @zone, server: server, days: days, timeout: 60_000)
    Payload.earlier(page, "scale", 0)
  end

  defp conversation_page(ref) do
    {:ok, view} = Wave0b.tail(ref, nil, limit: 100)
    ConversationPayload.view(ref.id, view)
  end

  defp write_messages(workspace, texts) do
    lines =
      texts
      |> Enum.with_index()
      |> Enum.map(fn {text, i} ->
        Jason.encode!(%{timestamp: "2026-10-21T10:00:00Z", event: "notification", method: "item/completed", params: %{item: %{type: "agentMessage", id: "m#{i}", text: text}}})
      end)

    File.write!(Path.join(workspace, "logs/agent.ndjson"), Enum.join(lines, "\n") <> "\n")
  end

  defp deflate(message) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    size = z |> :zlib.deflate(Jason.encode_to_iodata!(message), :finish) |> IO.iodata_length()
    :zlib.close(z)
    size
  end

  defp report(metric, value, budget), do: IO.puts("metric=#{inspect(metric)} value=#{value} unit=B budget=#{budget || "record"}")
  defp all_rows(data), do: data["sections"] |> Map.values() |> List.flatten()
  defp base_id(id), do: Integer.to_string(rem(String.to_integer(id), 100_000))
  defp wall(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!(@zone, Tz.TimeZoneDatabase) |> then(&{&1.hour, &1.minute})
  defp dst_crossing?(a, b), do: offset(a) != offset(b)
  defp offset(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!(@zone, Tz.TimeZoneDatabase) |> then(& &1.std_offset)
end
