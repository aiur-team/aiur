defmodule Aiur.AgentCompaction.StoreTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentCompaction.Store

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur_agent_compaction_store_test")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "stores and reloads the thread result outside the workspace", %{dir: dir} do
    opts = [dir: dir, repo_name: "store-test"]
    state = %{"thread_id" => "thr_1", "status" => "completed", "compacted_thread_id" => "thr_1"}
    assert :ok = Store.save("GH-42", state, opts)
    assert {:ok, ^state} = Store.load("GH-42", opts)
    assert Store.path_for("GH-42", dir, opts) == Path.join(dir, "store-test.GH-42.json")
  end

  test "missing state is distinct from unreadable state", %{dir: dir} do
    opts = [dir: dir, repo_name: "store-test"]
    assert {:ok, nil} = Store.load("absent", opts)

    path = Store.path_for("bad", dir, opts)
    File.mkdir_p!(dir)
    File.write!(path, "{broken")
    assert {:error, _} = Store.load("bad", opts)
  end
end
