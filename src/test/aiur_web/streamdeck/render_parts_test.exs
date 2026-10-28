defmodule AiurWeb.Streamdeck.RenderPartsTest do
  use ExUnit.Case, async: true

  @compile {:no_warn_undefined, [:xmerl_scan, :xmerl_xpath]}
  setup_all do
    paths = Path.wildcard(Path.join([to_string(:code.root_dir()), "lib", "xmerl-*", "ebin"]))
    Code.append_paths(paths)
    assert Code.ensure_loaded?(:xmerl_scan)
    :ok
  end

  alias AiurWeb.OperatorControlCenter.BuildOrderEpicIcon
  alias AiurWeb.Streamdeck.Render

  test "inlines shared epic and every bundled provider mark including the DeepSeek PNG" do
    for provider <- ~w(claude codex kimi openrouter muse deepseek) do
      image = Render.key(face(%{vendor: provider, icon: "runtime", priority: true}))
      xml = parse(image.svg)
      assert xpath(xml, "//text/text()") |> Enum.member?("★")
      assert length(xpath(xml, "//svg")) == 1
      expected_icon = BuildOrderEpicIcon.svg("runtime") |> parse()
      assert xpath(xml, "//g[@color]/g/g/path/@d") == xpath(expected_icon, "//path/@d")
      refute image.svg =~ "href=\"http"
      refute image.svg =~ "href=\"/"
      assert length(xpath(xml, "//svg/g[@transform]")) == 1

      if provider == "deepseek" do
        assert [href] = xpath(xml, "//image/@href")
        assert String.starts_with?(href, "data:image/png;base64,")

        assert {:ok, <<137, 80, 78, 71, _rest::binary>>} =
                 href |> String.replace_prefix("data:image/png;base64,", "") |> Base.decode64()
      end
    end
  end

  test "queued footers distinguish blocked and ready dependencies" do
    for {ready, label, color} <- [{false, "Blocked", "#ff9a90"}, {true, "Unblocked", "#88e0a6"}] do
      image = Render.key(face(%{bucket: :queued, dependency_ready: ready}))
      xml = parse(image.svg)
      assert xpath(xml, ~s|//text[@y="112"]/text()|) == [label]
      assert xpath(xml, ~s|//text[@y="112"]/@fill|) == [color]
      assert xpath(xml, ~s|//rect[@data-part="progress-fill"]|) == []
    end
  end

  test "rejects strip geometry beyond the canvas" do
    for region <- [
          %{x: -1, width: 200},
          %{x: 700, width: 200},
          %{x: 0, width: 0},
          %{x: 0, width: 1.5}
        ] do
      assert_raise ArgumentError, fn -> Render.strip([region]) end
    end
  end

  test "strip groups compose every primitive through one drawing path" do
    parts = [
      %{kind: :title_bar, title: "Group", label: "Work", percent: 100, freshness: :fresh},
      %{kind: :meter_row, label: "Quota", percent: 0, freshness: :fresh, y: 60},
      %{kind: :count_row, label: "2 live", y: 80},
      %{kind: :text_line, text: "Ready", y: 95},
      %{kind: :pager, label: "1 / 2", previous: true, next: true}
    ]

    [region] = Render.strip([%{x: 0, width: 800, label: "Group", parts: parts}])
    xml = parse(region.svg)

    assert xpath(xml, "//text/text()") == [
             "Group",
             "Work",
             "2 live",
             "Ready",
             "MORE AGENTS",
             "1 / 2",
             "‹",
             "›",
             "Quota 0%"
           ]

    assert length(xpath(xml, "//rect[@data-part=\"progress-fill\"]")) == 2
  end

  defp face(extra) do
    Map.merge(
      %{
        identifier: "#5181",
        title: "Fix strip squeeze",
        bucket: :running,
        icon: "runtime",
        vendor: "claude",
        progress_percent: 40,
        progress_freshness: "fresh"
      },
      extra
    )
  end

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
