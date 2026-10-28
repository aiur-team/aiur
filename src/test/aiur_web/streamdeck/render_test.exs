defmodule AiurWeb.Streamdeck.RenderTest do
  use ExUnit.Case, async: true

  # Mix prunes OTP applications outside the runtime dependency graph.
  @compile {:no_warn_undefined, [:xmerl_scan, :xmerl_xpath]}
  setup_all do
    paths = Path.wildcard(Path.join([to_string(:code.root_dir()), "lib", "xmerl-*", "ebin"]))
    Code.append_paths(paths)
    assert Code.ensure_loaded?(:xmerl_scan)
    :ok
  end

  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.Streamdeck.Render.Svg

  test "escapes hostile text and attributes into valid self-contained XML" do
    image = Render.key(face(%{title: "<script>&\"x", identifier: "#51<&", vendor: "\"><script>"}))
    xml = parse(image.svg)
    assert xpath(xml, "//text[@data-part=\"title-line\"]/text()") == ["<script>&\"x"]
    assert image.svg =~ "&lt;script&gt;&amp;"
    refute image.svg =~ "<script"
    assert image.label =~ "#51<& Running 40%"

    [region] = Render.strip([%{x: 0, width: 200, label: "\"<script>", parts: [%{kind: :text_line, text: "<script>&\""}]}])
    assert xpath(parse(region.svg), "//text/text()") == ["<script>&\""]
    refute region.svg =~ "<script"

    freshness = ~s|fresh" onload="bad<script>|
    hostile = Render.key(face(%{progress_freshness: freshness})) |> Map.fetch!(:svg) |> parse()
    assert xpath(hostile, ~s|//g[@data-freshness]/@data-freshness|) == [freshness]
    assert xpath(hostile, "//@onload") == []
  end

  test "wraps long titles within the fixed font budget and ellipsises the third line" do
    title = String.duplicate("a", 60)
    xml = face(%{title: title}) |> Render.key() |> Map.fetch!(:svg) |> parse()
    lines = xpath(xml, "//text[@data-part=\"title-line\"]/text()")
    budget = floor((120 - 2 * 9) / (0.6 * 14))
    assert length(lines) == 3
    assert Enum.all?(lines, &(String.length(&1) <= budget))
    assert List.last(lines) |> String.ends_with?("…")
    assert Svg.wrap("one two three", 7, 3) == ["one two", "three"]
    assert Svg.wrap(String.duplicate("界", 60), budget, 3) == [String.duplicate("界", 12), String.duplicate("界", 12), String.duplicate("界", 11) <> "…"]
  end

  test "unknown progress has only a grey track; measured zero has a visible fill and complete is brighter" do
    unknown = face(%{progress_percent: nil, progress_freshness: "unknown"}) |> Render.key()
    xml = parse(unknown.svg)
    assert xpath(xml, "//rect[@data-part=\"progress-track\"]/@fill") == ["#555b66"]
    assert xpath(xml, "//rect[@data-part=\"progress-fill\"]") == []
    assert unknown.label =~ "progress unknown"
    refute unknown.label =~ "0%"

    zero = face(%{progress_percent: 0}) |> Render.key() |> Map.fetch!(:svg) |> parse()
    assert xpath(zero, "//rect[@data-part=\"progress-fill\"]/@width") == ["6"]
    assert xpath(zero, "//rect[@data-part=\"progress-fill\"]/@fill") == ["#3fb950"]

    full = face(%{progress_percent: 100}) |> Render.key() |> Map.fetch!(:svg) |> parse()
    assert xpath(full, "//rect[@data-part=\"progress-fill\"]/@width") == ["102.0"]
    assert xpath(full, "//rect[@data-part=\"progress-fill\"]/@fill") == ["#74d47f"]

    stale = face(%{progress_freshness: "stale"}) |> Render.key()
    assert xpath(parse(stale.svg), "//g[@data-freshness=\"stale\"]/@opacity") == ["0.45"]
    assert stale.label =~ "40% stale"

    inconsistent = face(%{progress_percent: 50, progress_freshness: "unknown"}) |> Render.key()
    assert xpath(parse(inconsistent.svg), "//rect[@data-part=\"progress-fill\"]") == []
  end

  test "renders the real SD-101 grid adapter contract with eight slots and a tiled strip" do
    model = model()
    frame = Render.frame(model)
    assert length(frame.keys) == 8
    assert Enum.at(frame.keys, 0).label == "#5181 Running 40% — Fix strip squeeze"
    assert Enum.at(frame.keys, 4).label =~ "#5182 Unstarted"
    assert Enum.map([1, 2, 3, 5, 6, 7], &Enum.at(frame.keys, &1)) == List.duplicate(nil, 6)
    assert Enum.map(frame.strip, &{&1.x, &1.width}) == [{0, 200}, {200, 200}, {400, 200}, {600, 200}]
    assert hd(frame.strip).label == "1 live / 1 left; Build 41%"
    assert xpath(parse(hd(frame.strip).svg), "//rect[@data-part=\"progress-fill\"]/@width") == ["73.8"]
    assert Enum.at(frame.strip, 1).svg =~ "Session 75% left"
    assert Enum.at(frame.strip, 1).svg =~ "35s old stale"
    refute Enum.at(frame.strip, 1).svg =~ "Weekly"
    assert xpath(parse(Enum.at(frame.strip, 1).svg), ~s|//rect[@data-part="progress-fill"]/@width|) == ["135.0"]

    for image <- Enum.reject(frame.keys, &is_nil/1) do
      xml = parse(image.svg)
      assert xpath(xml, "/svg/@width") == ["120"]
      assert xpath(xml, "/svg/@height") == ["120"]
      assert xpath(xml, "/svg/@viewBox") == ["0 0 120 120"]
      assert byte_size(image.svg) <= 4096
    end

    for image <- frame.strip do
      xml = parse(image.svg)
      assert xpath(xml, "/svg/@viewBox") == ["0 0 #{image.width} 100"]
      assert xpath(xml, "/svg/@width") == [to_string(image.width)]
      assert xpath(xml, "/svg/@height") == ["100"]
      assert byte_size(image.svg) <= 6144
    end

    for image <- Enum.reject(frame.keys, &is_nil/1) ++ frame.strip do
      refute image.svg =~ ~r/href=["'](?:https?:|\/)/
      refute image.svg =~ "<script"
      assert image.svg =~ "JetBrains Mono, monospace"
      assert image.hash == :crypto.hash(:sha256, image.svg) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    end

    assert Render.frame(model) == frame
    assert Render.frame(wire(model)) == frame
    refute Render.key(face(%{title: "Changed"})).hash == hd(frame.keys).hash
  end

  test "preserves unavailable build, unknown percent, and provider states without fabricating zero" do
    for {status, build, expected} <- [
          {"unavailable", nil, "Build unavailable"},
          {"none", nil, "No build order"},
          {"ok", %{percent: nil}, "Build unknown"}
        ] do
      model = put_in(model(), [:grid, :build_status], status) |> put_in([:grid, :build], build)
      region = hd(Render.frame(model).strip)
      assert region.label =~ expected
      assert region.svg =~ expected
      assert xpath(parse(region.svg), "//rect[@data-part=\"progress-fill\"]") == []
    end

    meter = %{state: :unknown, freshness: :fresh, windows: %{session: %{used_percent: 75}}}
    strip = Render.frame(%{grid: %{agents: []}, usage: %{broken: meter}}).strip
    provider = Enum.at(strip, 1)
    assert provider.svg =~ "Session Unknown"
    assert xpath(parse(provider.svg), "//rect[@data-part=\"progress-fill\"]") == []
  end

  test "pages agents by columns and providers alphabetically with the same primitives" do
    agents = for id <- 1..12, do: face(%{identifier: "##{id}"})
    model = %{grid: %{agents: agents}, column_offset: 99, usage: %{d: nil, a: nil, c: nil, b: nil}, provider_offset: 99}
    frame = Render.frame(model)
    assert hd(frame.keys).label =~ "#5 Running"
    assert List.last(frame.keys).label =~ "#12 Running"
    assert Enum.map(frame.keys, &hd(String.split(&1.label))) == ~w(#5 #7 #9 #11 #6 #8 #10 #12)
    assert Enum.map(frame.strip, &{&1.x, &1.width}) == [{0, 200}, {200, 400}, {600, 200}]
    xml = parse(Enum.at(frame.strip, 1).svg)
    assert xpath(xml, "//text/text()") == ["b Unknown", "c Unknown", "d Unknown", "Providers 2–4 / 4"]
    assert List.last(frame.strip).label == "5–12 / 12"
    assert xpath(parse(List.last(frame.strip).svg), "//text/text()") == ["MORE AGENTS", "5–12 / 12", "‹", "·"]
    assert Render.frame(%{grid: %{agents: []}}).keys == List.duplicate(nil, 8)

    meter = %{state: :observed, freshness: :fresh, age_seconds: 35, windows: %{session: %{used_percent: 25}}}
    observed = Render.frame(%{usage: %{a: meter, b: meter, c: meter}}).strip |> Enum.at(1)
    observed_xml = parse(observed.svg)
    assert xpath(observed_xml, ~s|//text[@text-anchor="end"]/@y|) == ["16", "42", "68"]
    assert xpath(observed_xml, ~s|//text[@text-anchor="end"]/text()|) == List.duplicate("35s old", 3)
  end

  defp face(extra) do
    Map.merge(%{identifier: "#5181", title: "Fix strip squeeze", bucket: :running, icon: "runtime", vendor: "claude", progress_percent: 40, progress_freshness: "fresh"}, extra)
  end

  defp model do
    # The real SD-101 adapter output is merged into StreamdeckFleet.grid/1.
    grid =
      AiurWeb.StreamDeckGrid.project(%{running: [%{identifier: "#5181", title: "Fix strip squeeze", backend: :claude, progress_percent: 40}], idle: [%{identifier: "#5182", title: "Next ticket"}]})

    grid = Map.merge(grid, %{build: %{queue_id: "a", name: "X", completed: nil, resolved: 9, total: 22, percent: 41}, build_status: "ok"})
    %{grid: grid, usage: %{claude: %{state: :observed, freshness: :stale, age_seconds: 35, windows: %{session: %{used_percent: 25}}}, codex: %{state: :unknown}}}
  end

  defp wire(model), do: model |> Jason.encode!() |> Jason.decode!()
  defp parse(svg), do: svg |> :binary.bin_to_list() |> :xmerl_scan.string() |> elem(0)

  defp xpath(xml, path) do
    path
    |> String.to_charlist()
    |> :xmerl_xpath.string(xml)
    |> Enum.map(fn node ->
      case elem(node, 0) do
        :xmlText -> node |> elem(4) |> to_string()
        :xmlAttribute -> node |> elem(8) |> to_string()
        _ -> node
      end
    end)
  end
end
