defmodule AiurWeb.OperatorControlCenter.NavState do
  @moduledoc """
  Server-owned collapsed/expanded state for the dashboard sidebar.

  The collapsed flag lives in LiveView assigns rather than in a client-set DOM
  attribute: the shell element is server-rendered, so an attribute written only
  by JavaScript is discarded by the next LiveView patch. On a dashboard that
  re-renders on every telemetry tick, that reverted the toggle almost
  immediately (#1306).

  The client hook keeps `localStorage` for cross-navigation persistence and
  replays it once on mount through `restore/2`; the server remains the single
  source of truth for what is rendered.
  """

  @assign :nav_collapsed

  @doc "Seed the collapsed assign. Call from every `mount/3` that renders the shell."
  @spec assign_nav(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_nav(socket), do: Phoenix.Component.assign_new(socket, @assign, fn -> false end)

  @doc "Flip the collapsed state (the `toggle-nav` click)."
  @spec toggle(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle(socket) do
    Phoenix.Component.assign(socket, @assign, not collapsed?(socket))
  end

  @doc """
  Apply a client-restored value (from `localStorage`) exactly as given.

  Anything other than a boolean leaves the state untouched, so a corrupt or
  absent stored value degrades to the server default instead of raising.
  """
  @spec restore(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def restore(socket, collapsed) when is_boolean(collapsed),
    do: Phoenix.Component.assign(socket, @assign, collapsed)

  def restore(socket, _other), do: socket

  @doc "Current collapsed state."
  @spec collapsed?(Phoenix.LiveView.Socket.t()) :: boolean()
  def collapsed?(socket), do: socket.assigns[@assign] == true
end
