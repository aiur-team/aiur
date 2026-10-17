defmodule AiurWeb.Build.IndexReaderTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.IndexReader

  defmodule BrokenLoader do
    def load(:cached), do: raise("Units cache failed")
  end

  test "failed now reader drops old rows and leaves other sources usable" do
    previous = parts() |> put_in([:now, :rows], %{"12" => now_row(12)})
    read = IndexReader.read(MapSet.new(~w(now planned not_queued)a), previous, payload_loader: BrokenLoader)
    assert read.now == {:error, :read_failed}
    assert {:ok, index} = assemble(read)
    assert index.sources.agents.state == "unavailable"
    refute Map.has_key?(index.all, "12")
    assert index.sources.history.state == "ok"
  end

  test "cached open and queue facts keep every open id with no duplicate history read" do
    p = parts() |> put_in([:open, Access.key(:tickets)], [open(50, ["agent:todo"]), open(51, ["agent:human-review"]), open(53)])
    read = IndexReader.read(MapSet.new(~w(planned not_queued)a), p, [])
    assert {:ok, index} = assemble(read)
    assert Enum.sort(Map.keys(index.all)) == ~w(50 51 53)
    assert index.all["50"].sec == "plan"
    assert index.all["51"].sec == "nq" and index.all["53"].sec == "nq"
  end
end
