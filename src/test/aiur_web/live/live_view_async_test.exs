defmodule AiurWeb.LiveViewAsyncTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.TestSupport.LiveViewAsync

  @endpoint AiurWeb.Endpoint

  defmodule BarrierLive do
    use Phoenix.LiveView

    def mount(_params, %{"report" => report}, socket) do
      socket = assign(socket, :complete, false)

      {:ok,
       start_async(socket, :blocked, fn ->
         send(report, {:loader, self()})

         receive do
           :complete -> :complete
         end
       end)}
    end

    def handle_async(:blocked, {:ok, :complete}, socket), do: {:noreply, assign(socket, :complete, true)}

    def render(assigns) do
      ~H"""
      <p>{if @complete, do: "complete", else: "loading"}</p>
      """
    end
  end

  test "completion barrier waits past render_async's default deadline" do
    Aiur.TestSupport.start_owned_endpoint!()
    {:ok, view, _html} = live_isolated(build_conn(), BarrierLive, session: %{"report" => self()})
    receive_barrier({:loader, loader})
    waiter = Task.async(fn -> LiveViewAsync.render_when_complete(view) end)

    # Hold the real LiveView task beyond the framework's 100ms cutoff.
    assert Task.yield(waiter, 200) == nil
    send(loader, :complete)
    assert Task.await(waiter) =~ "<p>complete</p>"
  end
end
