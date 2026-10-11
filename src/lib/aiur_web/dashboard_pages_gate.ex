defmodule AiurWeb.DashboardPagesGate do
  @moduledoc """
  Refuses dashboard pages, static assets and LiveView mounts when the run shape
  serves the HTTP API without pages. A missing value means pages are on: that is
  the unchanged shape, so unlike the writable gate this one fails open.
  """

  @behaviour Plug

  @spec enabled?() :: boolean()
  def enabled? do
    AiurWeb.Endpoint.config(:dashboard_pages) != false
  rescue
    _ -> true
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Same bytes as the router catch-all, so pages-off is no oracle.
    if enabled?(), do: conn, else: conn |> AiurWeb.ObservabilityApiController.not_found(%{}) |> Plug.Conn.halt()
  end

  @doc "Closes a websocket mount, which never passes through the router pipeline."
  @spec on_mount(term(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(_hook, _params, _session, socket) do
    # LiveView requires a redirect on halt; "/" answers 404 in this shape.
    if enabled?(), do: {:cont, socket}, else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
  end
end
