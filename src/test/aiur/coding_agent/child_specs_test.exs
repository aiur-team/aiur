defmodule Aiur.CodingAgent.ChildSpecsTest do
  use ExUnit.Case, async: true

  alias Aiur.CodingAgent.ProvidersView

  test "child_specs/0 collects registry-declared children once, in init_order" do
    entries = %{
      "late" => %{init_order: 2, children: [Agent]},
      "early" => %{init_order: 1, children: [Task, Agent]},
      "none" => %{init_order: 0}
    }

    assert ProvidersView.child_specs(entries) == [Task, Agent]
  end
end
