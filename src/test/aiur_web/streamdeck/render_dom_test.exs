defmodule AiurWeb.Streamdeck.RenderDomTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Render

  test "inline keys namespace every gradient and preserve literal URL text" do
    images = for id <- ["one", "two"], do: Render.key(%{identifier: id, bucket: :running, vendor: "codex", title: "Keep url(#face)"})
    document = images |> Enum.map_join(& &1.svg) |> Floki.parse_fragment!()
    ids = Floki.attribute(document, "[id]", "id")
    assert length(ids) == length(Enum.uniq(ids))
    assert length(ids) >= 6

    for image <- images do
      tree = Floki.parse_fragment!(image.svg)
      assert Floki.find(tree, "svg > title") |> Floki.text() == image.label
      assert image.label =~ "Keep url(#face)"
      local_ids = Floki.attribute(tree, "[id]", "id")
      references = Regex.scan(~r/fill="url\(#([^)]+)\)"/, image.svg, capture: :all_but_first) |> List.flatten()
      assert length(references) >= 3
      for reference <- references, do: assert(reference in local_ids)
    end
  end

  test "all trusted provider and epic marks remain inside a single SVG root" do
    for provider <- ~w(claude codex deepseek kimi openrouter muse) do
      image = Render.key(%{identifier: provider, vendor: provider, bucket: :running, title: "Provider"})
      tree = Floki.parse_fragment!(image.svg)
      assert length(Floki.find(tree, "svg")) == 1
      assert length(Floki.find(tree, "svg g path, svg g image")) >= 2
    end
  end
end
