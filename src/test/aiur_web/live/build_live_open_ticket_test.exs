defmodule AiurWeb.BuildLiveOpenTicketTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.Build.DataSource

  defmodule Source do
    def subscribe(opts), do: FixtureSource.subscribe(opts)
    def snapshot(opts), do: FixtureSource.snapshot(opts)

    def ticket(id, opts) do
      send(opts[:test_pid], {:ticket_read, id})

      case opts[:ticket_mode] do
        :error -> {:error, :boom}
        :exit -> exit(:boom)
        :hold -> receive(do: (:release -> {:error, :unavailable}))
        :invalid -> {:ok, %{"id" => id}}
        _ -> FixtureSource.ticket(id, opts)
      end
    end
  end

  defp open_view(opts \\ []) do
    Application.put_env(:aiur, :build_data_source, {Source, Keyword.merge([test_pid: self(), dataset: "live"], opts)})
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    view
  end

  test "by-id read returns the exact row, including outside the loaded history window" do
    view = open_view(dataset: "dense")
    {:ok, full} = FixtureSource.full(dataset: "dense")
    {:ok, window} = FixtureSource.snapshot(dataset: "dense")
    row = Enum.min_by(full["sections"]["hist"], & &1["end"])
    assert row["end"] < window["history"]["from"]
    render_hook(view, "open-ticket", %{id: row["id"]})
    assert_reply(view, reply)
    assert reply["kind"] == "ticket"
    assert reply["row"] == row
    assert Payload.validate(reply) == :ok
    assert_received {:ticket_read, id}
    assert id == row["id"]
  end

  test "loaded notice assigns canonical id without reading; close clears it" do
    view = open_view()
    render_hook(view, "open-ticket", %{id: "007", loaded: true})
    assert_reply(view, reply)
    assert reply["kind"] == "ticket"
    refute Map.has_key?(reply, "row")
    assert Payload.validate(reply) == :ok
    assert :sys.get_state(view.pid).socket.assigns.open_ticket == "7"
    refute_received {:ticket_read, _}
    render_hook(view, "close-ticket", %{})
    assert :sys.get_state(view.pid).socket.assigns.open_ticket == nil
  end

  test "invalid ids never read or change the current ticket; valid ids are canonicalized" do
    view = open_view()
    render_hook(view, "open-ticket", %{id: "007"})
    assert_reply(view, %{"reason" => "not_found"})
    assert_received {:ticket_read, "7"}

    for params <- [%{}, %{id: %{}}, %{id: "AIUR-1"}, %{id: "0"}, %{id: "-3"}, %{id: "12a"}, %{id: "12345678901"}] do
      render_hook(view, "open-ticket", params)
      assert_reply(view, %{"kind" => "error", "reason" => "invalid_params"})
      assert :sys.get_state(view.pid).socket.assigns.open_ticket == "7"
      refute_received {:ticket_read, _}
    end
  end

  test "source errors, exits, invalid rows and the unwired default are unavailable" do
    for mode <- [:error, :exit, :invalid] do
      view = open_view(ticket_mode: mode)
      render_hook(view, "open-ticket", %{id: "7"})
      assert_reply(view, %{"kind" => "error", "reason" => "unavailable"})
      assert Process.alive?(view.pid)
    end

    view = open_view()
    :sys.replace_state(view.pid, fn state -> put_in(state.socket.assigns.build_source, DataSource) end)
    render_hook(view, "open-ticket", %{id: "7"})
    assert_reply(view, %{"reason" => "unavailable"})
  end

  test "slow source is bounded and leaves the LiveView alive" do
    view = open_view(ticket_mode: :hold)
    started = System.monotonic_time(:millisecond)
    render_hook(view, "open-ticket", %{id: "7"})
    assert_reply(view, %{"reason" => "unavailable"})
    assert System.monotonic_time(:millisecond) - started < 6_000
    assert Process.alive?(view.pid)
  end

  test "guard: ticket reads remain available on a read-only dashboard" do
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)
    view = open_view()
    row = hd(data()["sections"]["now"])
    render_hook(view, "open-ticket", %{id: row["id"]})
    assert_reply(view, %{"row" => ^row, "kind" => "ticket"})
  end

  test "each Build data source implements the by-id ticket read" do
    for source <- [AiurWeb.Build.DataSource, AiurWeb.Build.IndexSource, FixtureSource] do
      assert Code.ensure_loaded?(source)
      assert function_exported?(source, :ticket, 2), "#{inspect(source)} must implement ticket/2"
    end
  end
end
