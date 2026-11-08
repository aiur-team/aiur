defmodule Aiur.AgentTools.LaneTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.AgentTools.Dispatch
  alias Aiur.AgentTools.Lane
  alias Aiur.BuildOrder.EpicOverrides, as: Store

  setup do
    dir = Aiur.TestSupport.tmp_root!("lane-tool")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: name, repository: "acme/app", state_dir: dir, settings_fun: fn -> {:ok, %{build_order: %{lanes: [%{key: "bugs", label: "Bugs"}]}}} end})
    %{opts: [server: name]}
  end

  defp executor(issue, opts), do: ToolExecutor.build(issue, nil, nil, %{}, epic_opts: opts)

  test "V-27 V-28 actual executor binds string issue number, default ids and actor", c do
    tool = "aiur_set_lane"
    run = executor(%Aiur.Issue{id: "gid", identifier: "77"}, c.opts)
    assert run.(tool, %{"epic" => "bugs"})["success"]
    assert {:ok, %{77 => %{actor: "agent:77", source: "agent:77", confirmed: true}}, _} = Store.all(c.opts)
    assert run.(tool, %{"epic" => "bugs", "ids" => [88]})["success"]
    assert {:ok, %{88 => %{actor: "agent:77"}}, _} = Store.all(c.opts)
    bad = executor(%Aiur.Issue{id: "gid", identifier: "ENG-7"}, c.opts)
    assert bad.(tool, %{"epic" => "bugs"})["success"] == false
    assert {:ok, rows, _} = Store.all(c.opts)
    assert Enum.sort(Map.keys(rows)) == [77, 88]
  end

  test "V-29 backfill is unconfirmed and clear uses bound identity", c do
    run = executor(%Aiur.Issue{id: "gid", identifier: "77"}, c.opts)
    assert run.("aiur_set_lane", %{"epic" => "bugs", "backfill" => true})["success"]
    assert {:ok, %{77 => %{actor: "agent:77", source: "backfill-agent", confirmed: false}}, _} = Store.all(c.opts)
    assert run.("aiur_set_lane", %{"clear" => true})["success"]
    assert {:ok, entries} = Store.journal([77], c.opts)
    assert Map.take(List.last(entries), [:op, :number, :seq, :actor, :source]) == %{op: "clear", number: 77, seq: 2, actor: "agent:77", source: "agent:77"}
  end

  test "V-28 V-29b rejects provenance injection and conflicting arguments before setter" do
    for args <- [
          %{"epic" => "bugs", "actor" => "agent:9"},
          %{"epic" => "bugs", "source" => "cli:x"},
          %{"clear" => true, "epic" => "bugs"},
          %{"clear" => true, "backfill" => true},
          %{"epic" => "bugs", "ids" => ["77"]},
          %{"epic" => "bugs", "ids" => []},
          %{"clear" => "yes"},
          %{},
          nil
        ] do
      assert {:error, :invalid_epic_arguments} = Lane.normalize(args)

      for tool <- ["aiur_set_lane", "aiur_set_epic"] do
        assert Dispatch.execute(tool, args, epic_setter: fn _ -> flunk("setter must not be called") end)["success"] == false
      end
    end

    assert Enum.all?(Lane.specs(), &(&1["inputSchema"]["additionalProperties"] == false))
  end

  test "unknown lane returns known keys to agent", c do
    run = executor(%Aiur.Issue{id: "gid", identifier: "77"}, c.opts)
    result = run.("aiur_set_lane", %{"epic" => "nope"})
    assert result["success"] == false
    assert Jason.decode!(result["output"])["error"]["known"] == ["bugs"]
    assert Dispatch.execute("aiur_set_lane", %{"epic" => "bugs"})["success"] == false
  end

  test "aiur_set_epic is an alias naming the same spec and the same effect", c do
    assert Enum.map(Lane.specs(), & &1["name"]) == ["aiur_set_lane", "aiur_set_epic"]
    [lane_spec, epic_spec] = Lane.specs()
    assert lane_spec["inputSchema"] == epic_spec["inputSchema"]
    assert epic_spec["description"] =~ "aiur_set_lane"

    lane_run = executor(%Aiur.Issue{id: "gid", identifier: "77"}, c.opts)
    assert lane_run.("aiur_set_lane", %{"epic" => "bugs"})["success"]
    assert {:ok, %{77 => lane_row}, _} = Store.all(c.opts)

    epic_run = executor(%Aiur.Issue{id: "gid", identifier: "77"}, c.opts)
    assert epic_run.("aiur_set_epic", %{"epic" => "bugs"})["success"]
    assert {:ok, %{77 => epic_row}, _} = Store.all(c.opts)

    assert Map.drop(lane_row, [:at]) == Map.drop(epic_row, [:at])
  end
end
