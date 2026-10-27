defmodule Aiur.CodingAgent.ChildSpecsTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent.ProvidersView

  test "child_specs/0 collects registry-declared children once, in init_order" do
    entries = %{
      "a-late" => %{init_order: 2, children: [Agent]},
      "b-early" => %{init_order: 1, children: [Task, Agent]},
      "c-none" => %{init_order: 0}
    }

    assert ProvidersView.child_specs(entries) == [Task, Agent]
  end
end
