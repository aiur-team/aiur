defmodule Aiur.Events.ExchangeRestartRebindTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Application, as: AiurApp
  alias Aiur.Events.Exchange

  defmodule Probe do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      :ok = Exchange.subscribe("ticket.*.#", Keyword.fetch!(opts, :exchange))
      parent = Keyword.fetch!(opts, :parent)
      send(parent, {:probe_started, self()})
      {:ok, parent}
    end

    @impl true
    def handle_info({:event, event}, parent) do
      send(parent, {:probe_event, self(), event})
      {:noreply, parent}
    end
  end

  setup do
    exchange = Module.concat(__MODULE__, "Exchange#{System.unique_integer([:positive])}")
    exchange_child = %{id: Exchange, start: {__MODULE__, :start_exchange, [[name: exchange], self()]}, modules: [Exchange]}
    children = [exchange_child, {Probe, exchange: exchange, parent: self()}]

    supervisor =
      start_supervised!(%{
        id: :isolated_bus,
        start: {AiurApp, :start_supervisor, [children]},
        type: :supervisor
      })

    receive_barrier({:exchange_started, _exchange})
    receive_barrier({:probe_started, probe})
    %{supervisor: supervisor, exchange: exchange, probe: probe}
  end

  # Guards existing behaviour for C2–C6 moves; deliberately green on main.
  test "a subscriber after the Exchange re-binds after the Exchange is killed", context do
    probe = restart_exchange(context)
    assert Exchange.bindings_for(probe, context.exchange) == ["ticket.*.#"]

    assert Exchange.publish("ticket.3348.agent.progress", :after_restart, context.exchange) == 1
    receive_barrier({:probe_event, ^probe, :after_restart})
  end

  test "events published before the restart are not redelivered to the new subscriber", context do
    previous_probe = context.probe
    assert Exchange.publish("ticket.3348.agent.progress", :before_restart, context.exchange) == 1
    receive_barrier({:probe_event, ^previous_probe, :before_restart})

    probe = restart_exchange(context)
    assert Exchange.publish("ticket.3348.agent.progress", :after_restart, context.exchange) == 1
    receive_barrier({:probe_event, ^probe, :after_restart})
    refute_received {:probe_event, ^probe, :before_restart}
  end

  # Announce Exchange init so the supervisor call below can fence the whole cascade.
  def start_exchange(opts, parent) do
    {:ok, exchange} = Exchange.start_link(opts)
    send(parent, {:exchange_started, exchange})
    {:ok, exchange}
  end

  defp restart_exchange(context) do
    previous_exchange = Process.whereis(context.exchange)
    monitor = Process.monitor(previous_exchange)
    Process.exit(previous_exchange, :kill)
    receive_barrier({:DOWN, ^monitor, :process, ^previous_exchange, :killed})
    receive_barrier({:exchange_started, restarted_exchange})

    children = Supervisor.which_children(context.supervisor)
    assert {Exchange, exchange, :worker, [Exchange]} = List.keyfind(children, Exchange, 0)
    assert exchange == restarted_exchange
    assert exchange != previous_exchange
    assert {Probe, probe, :worker, [Probe]} = List.keyfind(children, Probe, 0)
    assert probe != context.probe
    probe
  end
end
