defmodule Aiur.BuildOrder.Features.LabelRegistryRaceTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildOrder.Features
  alias Aiur.TestSupport.FeatureLabelFixture, as: F
  setup do: F.setup()

  test "label-origin join racing a CLI join preserves its selected epic and provenance", ctx do
    assert {:ok, _} = Features.add_epic("auth", %{key: "f-special", label: "Special"}, F.meta(ctx))
    assert {:ok, _} = Features.add("auth", [12], F.meta(ctx) ++ [epic: "f-special"])
    assert {:ok, before} = Features.owner(12, server: ctx.features)
    assert {:ok, %{changed: []}} = Features.add("auth", [12], F.meta(ctx, "label:unknown"))
    assert Features.owner(12, server: ctx.features) == {:ok, before}
    assert before.epic == "f-special"
    assert before.source == "cli:test"
  end
end
