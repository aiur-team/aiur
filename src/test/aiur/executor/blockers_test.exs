defmodule Aiur.Executor.BlockersTest do
  use ExUnit.Case, async: true
  alias Aiur.{AlertFeed, Decision}
  alias Aiur.Executor.Blockers

  defmodule Store do
    use GenServer
    def start_link(health), do: GenServer.start_link(__MODULE__, health)
    @impl true
    def init(health), do: {:ok, health}
    @impl true
    def handle_call(:list, _from, health), do: {:reply, [], health}

    def handle_call(:retained_counts, _from, health), do: {:reply, {:error, :store_unavailable}, health}
  end

  setup do
    now = DateTime.utc_now()
    {:ok, now: now, opts: [now: now, commands_fun: fn -> [] end, asks_fun: fn -> {:ok, []} end, fleet_fun: fn -> [] end]}
  end

  test "all empty sources are available", %{now: now, opts: opts} do
    assert Blockers.snapshot(opts) == %{items: [], sources: %{commands: :ok, asks: :ok, fleet: :ok}, observed_at: now}
  end

  test "Executor Commands have links, filter closed and worker Commands, and sort oldest first", %{now: now, opts: opts} do
    older = command("older", DateTime.add(now, -60, :second))
    newer = command("newer", DateTime.add(now, -10, :second))
    worker = %{older | decision_id: "worker", requester: %{kind: :worker}}
    closed = %{older | decision_id: "closed", decision_status: :resolved}
    result = Blockers.snapshot(Keyword.put(opts, :commands_fun, fn -> [newer, worker, closed, older] end))

    assert result.items == [
             %{kind: :command, id: "older", title: "Help older", age_ms: 60_000, link: "/commands/older"},
             %{kind: :command, id: "newer", title: "Help newer", age_ms: 10_000, link: "/commands/newer"}
           ]

    assert result.sources.commands == :ok
  end

  test "one failing source is unavailable and preserves Commands", %{now: now, opts: opts} do
    result =
      opts
      |> Keyword.put(:commands_fun, fn -> [command("kept", now)] end)
      |> Keyword.put(:asks_fun, fn -> {:error, :corrupt} end)
      |> Blockers.snapshot()

    assert [%{id: "kept", link: "/commands/kept"}] = result.items
    assert result.sources == %{commands: :ok, asks: {:unavailable, :corrupt}, fleet: :ok}
  end

  test "crashes and timeouts are isolated", %{opts: opts} do
    opts =
      opts
      |> Keyword.put(:timeout, 500)
      |> Keyword.put(:commands_fun, fn -> exit({:noproc, {GenServer, :call, []}}) end)
      |> Keyword.put(:asks_fun, fn ->
        receive do
          :never -> {:ok, []}
        end
      end)
      |> Keyword.put(:fleet_fun, fn -> raise ArgumentError end)

    assert %{items: [], sources: %{commands: {:unavailable, :decision_store_down}, asks: {:unavailable, :timeout}, fleet: {:unavailable, {:exception, ArgumentError}}}} = Blockers.snapshot(opts)
  end

  test "legacy asks retain title and age; fleet includes only bound system attentions", %{now: now, opts: opts} do
    timestamp = now |> DateTime.add(-30, :second) |> DateTime.to_iso8601()
    ask = %{"id" => "ask_old", "title" => "Legacy help", "created_at" => timestamp}
    alert = %{"topic" => "system.fleet.capacity.starved", "message" => "Capacity needed", "needs_attention" => true, "timestamp" => timestamp}

    result =
      opts
      |> Keyword.put(:asks_fun, fn -> {:ok, [ask]} end)
      |> Keyword.put(:fleet_fun, fn -> [alert, %{alert | "topic" => "system.unbound"}, %{alert | "needs_attention" => false}, %{alert | "topic" => "ticket.1.agent.attention.help"}] end)
      |> Blockers.snapshot()

    assert result.items == [
             %{kind: :ask, id: "ask_old", title: "Legacy help", age_ms: 30_000, link: "/commands"},
             %{kind: :fleet, id: "system.fleet.capacity.starved", title: "Capacity needed", age_ms: 30_000, link: "/"}
           ]

    assert result.sources.fleet == :ok
  end

  test "strict fleet reads distinguish unreadable paths from malformed records", %{opts: opts} do
    path = Path.join(System.tmp_dir!(), "blockers-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    File.mkdir_p!(path)

    result = Blockers.snapshot(Keyword.put(opts, :fleet_fun, fn -> AlertFeed.list(ledger_path: path, strict: true) end))
    assert result.sources.fleet == {:unavailable, {:exception, File.Error}}
    assert result.items == []

    ledger = Path.join(path, "corrupt")
    File.write!(ledger, "invalid json\n")
    result = Blockers.snapshot(Keyword.put(opts, :fleet_fun, fn -> AlertFeed.list(ledger_path: ledger, strict: true) end))
    assert result.sources.fleet == :ok
    assert result.items == []
  end

  test "malformed and torn records do not hide active fleet blockers", %{now: now, opts: opts} do
    path = Path.join(System.tmp_dir!(), "blockers-torn-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    alert = fleet_alert("system.fleet.capacity.starved", "Capacity needed", now)
    line = Jason.encode!(alert) <> "\n"
    fragment = ~s({"event":"alert","topi)
    read = fn -> AlertFeed.list(ledger_path: path, strict: true) end

    for contents <- [fragment <> "\n" <> line, line <> fragment, fragment <> line <> line] do
      File.write!(path, contents)
      result = Blockers.snapshot(Keyword.put(opts, :fleet_fun, read))
      assert result.sources.fleet == :ok
      assert result.items == [%{kind: :fleet, id: "system.fleet.capacity.starved", title: "Capacity needed", age_ms: 0, link: "/"}]
    end
  end

  test "strict fleet reads keep only the bounded tail", %{now: now, opts: opts} do
    path = Path.join(System.tmp_dir!(), "blockers-tail-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    older = Jason.encode!(fleet_alert("system.github.connectivity_lost", "Old blocker", DateTime.add(now, -60, :second))) <> "\n"
    newest = Jason.encode!(fleet_alert("system.fleet.capacity.starved", "Recent blocker", now)) <> "\n"
    padding = Jason.encode!(%{"padding" => String.duplicate("x", 512)}) <> "\n"
    File.write!(path, [older, padding, newest])
    read = fn -> AlertFeed.list(ledger_path: path, strict: true, max_bytes: byte_size(newest) + 1) end
    result = Blockers.snapshot(Keyword.put(opts, :fleet_fun, read))

    assert result.sources.fleet == :ok
    assert result.items == [%{kind: :fleet, id: "system.fleet.capacity.starved", title: "Recent blocker", age_ms: 0, link: "/"}]
  end

  test "strict fleet read resolves cleared conditions and accepts a missing ledger", %{now: now, opts: opts} do
    path = Path.join(System.tmp_dir!(), "blockers-ledger-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    read = fn -> AlertFeed.list(ledger_path: path, strict: true) end
    assert Blockers.snapshot(Keyword.put(opts, :fleet_fun, read)).sources.fleet == :ok
    alert = %{"event" => "alert", "topic" => "system.fleet.capacity.starved", "needs_attention" => true, "message" => "Capacity", "timestamp" => DateTime.to_iso8601(now)}
    File.write!(path, Jason.encode!(alert) <> "\n")
    assert [%{kind: :fleet, title: "Capacity"}] = Blockers.snapshot(Keyword.put(opts, :fleet_fun, read)).items
    File.write!(path, Jason.encode!(%{alert | "topic" => "system.fleet.capacity.starved.resolved", "needs_attention" => false}) <> "\n", [:append])
    assert Blockers.snapshot(Keyword.put(opts, :fleet_fun, read)).items == []
  end

  test "default Command reader preserves unavailable persistence causes", %{opts: opts} do
    store = start_supervised!({Store, {:unavailable, :eacces}})
    result = opts |> Keyword.delete(:commands_fun) |> Keyword.put(:store, store) |> Blockers.snapshot()
    assert result.sources.commands == {:unavailable, :retained_store_unavailable}
    assert result.items == []
  end

  test "default Command reader reports an absent process separately", %{opts: opts} do
    store = start_supervised!({Store, :writable})
    stop_supervised!(Store)
    result = opts |> Keyword.delete(:commands_fun) |> Keyword.put(:store, store) |> Blockers.snapshot()
    assert result.sources.commands == {:unavailable, :decision_store_down}
  end

  defp fleet_alert(topic, message, now),
    do: %{"event" => "alert", "topic" => topic, "needs_attention" => true, "message" => message, "timestamp" => DateTime.to_iso8601(now)}

  defp command(id, timestamp) do
    struct(Decision, decision_id: id, version: 1, question: "Help #{id}", created_at: timestamp, requester: %{kind: :executor}, decision_status: :open)
  end
end
