defmodule Aiur.AppServer.ToolResultSpillTest do
  use ExUnit.Case, async: true

  alias Aiur.AppServer.ToolResultSpill

  @max_inline_bytes 100 * 1024

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur-spill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp big_result do
    payload = String.duplicate("x", @max_inline_bytes + 1)
    %{"success" => true, "output" => payload, "contentItems" => [%{"type" => "inputText", "text" => payload}]}
  end

  test "spills oversized result to workspace and returns pointer", %{tmp: tmp} do
    workspace = Path.join(tmp, "ws")
    File.mkdir_p!(workspace)

    result = big_result()
    context = %{workspace: workspace, response_id: "r1"}

    spilled = ToolResultSpill.maybe_spill(result, context)

    assert %{"success" => true, "output" => msg} = spilled
    assert msg =~ ".aiur-runtime/tool-results"
    assert msg =~ ".json"

    [path] = Path.wildcard(Path.join([workspace, ".aiur-runtime", "tool-results", "*.json"]))
    assert File.exists?(path)
  end

  test "does not spill inline-sized result", %{tmp: tmp} do
    workspace = Path.join(tmp, "ws")
    File.mkdir_p!(workspace)

    result = %{"success" => true, "output" => "small", "contentItems" => []}
    context = %{workspace: workspace, response_id: "r1"}

    assert ToolResultSpill.maybe_spill(result, context) == result
  end

  test "rejects a symlinked .aiur-runtime directory", %{tmp: tmp} do
    workspace = Path.join(tmp, "ws")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(workspace, ".aiur-runtime"))

    result = big_result()
    context = %{workspace: workspace, response_id: "r2"}

    spilled = ToolResultSpill.maybe_spill(result, context)

    assert %{"success" => false} = spilled
    assert File.ls!(outside) == []
  end

  test "rejects a symlinked tool-results directory", %{tmp: tmp} do
    workspace = Path.join(tmp, "ws")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join(workspace, ".aiur-runtime"))
    File.ln_s!(outside, Path.join([workspace, ".aiur-runtime", "tool-results"]))

    result = big_result()
    context = %{workspace: workspace, response_id: "r3"}

    spilled = ToolResultSpill.maybe_spill(result, context)

    assert %{"success" => false} = spilled
    assert File.ls!(outside) == []
  end

  test "no bytes land outside workspace under concurrent directory swap", %{tmp: tmp} do
    workspace = Path.join(tmp, "ws")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)

    runtime = Path.join(workspace, ".aiur-runtime")
    results = Path.join(runtime, "tool-results")
    File.mkdir_p!(results)
    File.chmod!(results, 0o700)

    parent = self()

    attacker =
      Task.async(fn ->
        swaps =
          Enum.reduce(1..300, 0, fn _, acc ->
            try do
              File.rm_rf!(results)
              File.ln_s!(outside, results)
              Process.sleep(1)
              File.rm!(results)
              File.mkdir!(results)
              File.chmod!(results, 0o700)
              acc + 1
            rescue
              _ -> acc
            end
          end)

        send(parent, {:attacker_done, swaps})
      end)

    result = big_result()

    Enum.each(1..50, fn i ->
      ToolResultSpill.maybe_spill(result, %{workspace: workspace, response_id: "swap-#{i}"})
    end)

    swaps =
      receive do
        {:attacker_done, n} -> n
      after
        15_000 -> flunk("attacker task timed out")
      end

    Task.await(attacker, 15_000)

    assert swaps > 0, "no symlink swaps completed — adversarial scenario was not exercised"

    outside_files = File.ls!(outside)
    assert outside_files == [], "files escaped workspace: #{inspect(outside_files)}"
  end
end
