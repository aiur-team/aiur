defmodule AiurWeb.OperatorControlCenter.AwaitingCommands do
  @moduledoc """
  Canonical awaiting-Command counts for the routes that are not the Commands
  page.

  A blocking Command is the one thing that stops the fleet, so every route
  carries the banner. Each route reads the same canonical retained counts the
  Commands page reads, and refreshes them from the Decision PubSub signal, so no
  page can sit on a number the Commands page has already moved past. When the
  store cannot be read the counts are `nil` and the banner renders nothing
  rather than a zero.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Aiur.DecisionPubSub
  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.DecisionProvider
  alias Phoenix.LiveView.Socket

  @unavailable %{
    open: nil,
    blocking: nil,
    total: nil,
    awaiting: nil,
    awaiting_blocking: nil,
    deferred: nil,
    health: %{status: :unavailable, label: "Command counts unavailable"}
  }

  @tick_ms 10_000

  @doc "Subscribes to Command changes (when connected) and assigns the first counts."
  @spec mount(Socket.t(), boolean()) :: Socket.t()
  def mount(socket, connected?) do
    if connected? do
      DecisionPubSub.subscribe()
      schedule_tick()
    end

    refresh(socket)
  end

  @doc """
  Handles the periodic re-read.

  The PubSub signal is best-effort, so a missed broadcast must not leave a page
  showing a count the Commands page has moved past. The tick bounds how long a
  banner can be wrong to `#{@tick_ms}ms`.
  """
  @spec tick(Socket.t()) :: Socket.t()
  def tick(socket) do
    schedule_tick()
    refresh(socket)
  end

  defp schedule_tick, do: Process.send_after(self(), :awaiting_commands_tick, @tick_ms)

  @doc "Re-reads the canonical counts. Safe to call on every Command signal."
  @spec refresh(Socket.t()) :: Socket.t()
  def refresh(socket) do
    counts = counts()

    socket
    |> assign(:retained_counts, counts)
    |> assign(:nav_counts, nav_counts(counts))
  end

  @doc "Nav badge counts derived from the same read, and the same field, as the banner."
  @spec nav_counts(map()) :: map()
  def nav_counts(%{awaiting: awaiting}) when is_integer(awaiting) and awaiting > 0,
    do: %{commands: awaiting}

  def nav_counts(_counts), do: %{}

  # The provider answers `{:ok, counts}` even for an unreadable store, so an
  # error tuple is not a case to branch on — but a store that is down exits or
  # raises, and that must leave the banner with no number rather than a zero.
  defp counts do
    {:ok, counts} = DecisionProvider.counts(decision_store: decision_store())
    counts
  rescue
    _error -> @unavailable
  catch
    :exit, _reason -> @unavailable
  end

  defp decision_store, do: Endpoint.config(:decision_store) || Aiur.DecisionStore
end
