defmodule AiurWeb.Build.IndexReaderTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.IndexReader

  defmodule BrokenLoader do
    def load(:cached), do: raise("Units cache failed")
  end

  defmodule SlowOpenServer do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_cast(:block, parent) do
      send(parent, :open_read_blocked)
      Process.sleep(300)
      {:noreply, parent}
    end

    def handle_call(:snapshot, _from, parent), do: {:reply, %Aiur.OpenTicketSource.Snapshot{}, parent}
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

  test "an open snapshot timeout keeps other timeline rows and names the degraded source" do
    server = start_supervised!({SlowOpenServer, self()})
    GenServer.cast(server, :block)
    assert_receive :open_read_blocked, 1_000

    previous = parts([row(40)]) |> put_in([:now, :rows], %{"41" => now_row(41)})

    read =
      IndexReader.read(MapSet.new(~w(open planned not_queued)a), previous,
        open_server: server,
        open_timeout: 5
      )

    assert read.open == {:error, :timeout}
    assert {:ok, index} = assemble(read)
    assert Map.has_key?(index.all, "40")
    assert Map.has_key?(index.all, "41")
    assert index.sources.open_tickets.reason == "open_tickets_timeout"
  end
end
