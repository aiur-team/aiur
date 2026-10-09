defmodule Aiur.Codex.DynamicTool.EpicTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.BuildOrder.EpicOverrides, as: Store
  alias Aiur.Codex.DynamicTool
  alias Aiur.Codex.DynamicTool.Epic

  setup do
    dir = Aiur.TestSupport.tmp_root!("epic-tool")
    on_exit(fn -> File.rm_rf!(dir) end)
    name = Module.concat(__MODULE__, "S#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: name, repository: "acme/app", state_dir: dir, settings_fun: fn -> {:ok, %{build_order: %{general_epics: [%{key: "bugs", label: "Bugs"}]}}} end})
    %{opts: [server: name]}
  end

  defp executor(issue, opts), do: ToolExecutor.build(issue, nil, nil, %{}, epic_opts: opts)

  test "V-27 V-28 actual executor binds string issue number, default ids and actor", c do
    run = executor(%Aiur.Issue{id: "gid", identifier: "77"}, c.opts)
    assert run.("aiur_set_epic", %{"epic" => "bugs"})["success"]
    assert {:ok, %{77 => %{actor: "agent:77", source: "agent:77", confirmed: true}}, _} = Store.all(c.opts)
    assert run.("aiur_set_epic", %{"epic" => "bugs", "ids" => [88]})["success"]
    assert {:ok, %{88 => %{actor: "agent:77"}}, _} = Store.all(c.opts)
    bad = executor(%Aiur.Issue{id: "gid", identifier: "ENG-7"}, c.opts)
    assert bad.("aiur_set_epic", %{"epic" => "bugs"})["success"] == false
    assert {:ok, rows, _} = Store.all(c.opts)
    assert Enum.sort(Map.keys(rows)) == [77, 88]
  end

  test "V-29 backfill is unconfirmed and clear uses bound identity", c do
    run = executor(%Aiur.Issue{id: "gid", identifier: "77"}, c.opts)
    assert run.("aiur_set_epic", %{"epic" => "bugs", "backfill" => true})["success"]
    assert {:ok, %{77 => %{actor: "agent:77", source: "backfill-agent", confirmed: false}}, _} = Store.all(c.opts)
    assert run.("aiur_set_epic", %{"clear" => true})["success"]
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
      assert {:error, :invalid_epic_arguments} = Epic.normalize(args)
      assert DynamicTool.execute("aiur_set_epic", args, epic_setter: fn _ -> flunk("setter must not be called") end)["success"] == false
    end

    assert hd(Epic.specs())["inputSchema"]["additionalProperties"] == false
  end

  test "unknown epic returns known keys to agent", c do
    run = executor(%Aiur.Issue{id: "gid", identifier: "77"}, c.opts)
    result = run.("aiur_set_epic", %{"epic" => "nope"})
    assert result["success"] == false
    assert Jason.decode!(result["output"])["error"]["known"] == ["bugs"]
    assert DynamicTool.execute("aiur_set_epic", %{"epic" => "bugs"})["success"] == false
  end
end
