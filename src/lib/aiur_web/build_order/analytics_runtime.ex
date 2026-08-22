defmodule AiurWeb.BuildOrder.AnalyticsRuntime do
  @moduledoc """
  Selected-scope long-run analytics integration for the Build Order route.

  Reducing the durable telemetry stream means parsing every NDJSON record the
  daemon has ever written, so the load always runs through `start_async/3` and
  never on the render path. Results are keyed by the membership key captured at
  request time and dropped when it no longer matches, so one Build Order's
  telemetry can never render under another root's URL.

  The stream grows while a run is in flight, so the pane re-reads on the Build
  Order page's existing UI tick — but at most once per refresh window, which is
  what keeps a once-per-second tick from re-parsing the stream once per second.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3]

  alias Aiur.{PollCadence, TrackerIdentity}
  alias AiurWeb.BuildOrder.{AnalyticsScope, RouteState}
  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.Analytics.Presenter
  alias Phoenix.LiveView.Socket

  @refresh_ms 30_000

  @doc "Assigns the content-free analytics state before any telemetry read."
  @spec initialize(Socket.t()) :: Socket.t()
  def initialize(socket) do
    socket
    |> assign(:bo_analytics_scope, %{state: :none, reason: nil, rejected: 0, graph_health: :ready, total: 0})
    |> assign(:bo_analytics_model, nil)
    |> assign(:bo_analytics_unavailable, nil)
    |> assign(:bo_analytics_key, nil)
    |> assign(:bo_analytics_identity, nil)
    |> assign(:bo_analytics_loading?, false)
    |> assign(:bo_analytics_loaded_at, nil)
  end

  @doc """
  Re-derives the scope after any route-state change and reconciles the pane.

  Drops every retained fact on a selected-root switch, renders the immediate
  scope-level state, and starts one asynchronous read when the current member set
  has no telemetry loaded yet.
  """
  @spec sync_scope(Socket.t()) :: Socket.t()
  def sync_scope(socket) do
    socket
    |> reset_on_identity_change(current_identity(socket.assigns.route_state))
    |> reconcile(AnalyticsScope.decide(socket.assigns.route_state))
  end

  @doc "Re-reads the stream on the page tick once the retained model is older than the refresh window."
  @spec tick(Socket.t()) :: Socket.t()
  def tick(socket) do
    if stale?(socket), do: reconcile(socket, AnalyticsScope.decide(socket.assigns.route_state), force: true), else: socket
  end

  @doc "Accepts an async result, ignoring one whose membership key no longer matches."
  @spec complete(Socket.t(), AnalyticsScope.membership_key(), term()) :: Socket.t()
  def complete(socket, key, result) do
    if key == socket.assigns.bo_analytics_key do
      socket
      |> assign(:bo_analytics_loading?, false)
      |> assign(:bo_analytics_loaded_at, System.monotonic_time(:millisecond))
      |> apply_result(result)
    else
      socket
    end
  end

  @doc "Records a failed async read without discarding an already-rendered model."
  @spec failed(Socket.t(), AnalyticsScope.membership_key()) :: Socket.t()
  def failed(socket, key) do
    if key == socket.assigns.bo_analytics_key do
      socket
      |> assign(:bo_analytics_loading?, false)
      |> assign(:bo_analytics_loaded_at, System.monotonic_time(:millisecond))
      |> preserve_model_or_mark_unavailable()
    else
      socket
    end
  end

  defp preserve_model_or_mark_unavailable(%{assigns: %{bo_analytics_model: model}} = socket) when not is_nil(model), do: socket
  defp preserve_model_or_mark_unavailable(socket), do: assign(socket, :bo_analytics_unavailable, :error)

  # --- reconciliation ------------------------------------------------------

  defp reconcile(socket, decision, opts \\ [])

  defp reconcile(socket, {:ready, scope, key, graph_health}, opts) do
    socket = put_scope(socket, :ready, graph_health: graph_health, total: scope.total, rejected: scope.rejected)

    cond do
      socket.assigns.bo_analytics_loading? -> socket
      key == socket.assigns.bo_analytics_key and not Keyword.get(opts, :force, false) -> socket
      true -> start_load(socket, scope, key)
    end
  end

  defp reconcile(socket, :none, _opts), do: scope_only(socket, :none)
  defp reconcile(socket, :pending, _opts), do: scope_only(socket, :pending)
  defp reconcile(socket, {:invalid, reason}, _opts), do: scope_only(socket, :invalid, reason: reason)
  defp reconcile(socket, {:unavailable, reason}, _opts), do: scope_only(socket, :graph_unavailable, reason: reason)
  defp reconcile(socket, :empty_build, _opts), do: scope_only(socket, :empty_build)
  defp reconcile(socket, {:unscopable, rejected}, _opts), do: scope_only(socket, :unscopable, rejected: rejected)

  # A non-ready scope renders its own state and never a zero-valued model, which
  # would read as "this build burned nothing" rather than "nothing is scoped".
  defp scope_only(socket, state, opts \\ []) do
    socket
    |> put_scope(state, opts)
    |> assign(:bo_analytics_model, nil)
    |> assign(:bo_analytics_unavailable, nil)
  end

  defp put_scope(socket, state, opts) do
    scope = %{
      state: state,
      reason: Keyword.get(opts, :reason),
      rejected: Keyword.get(opts, :rejected, 0),
      graph_health: Keyword.get(opts, :graph_health, :ready),
      total: Keyword.get(opts, :total, 0)
    }

    assign(socket, :bo_analytics_scope, scope)
  end

  # The disconnected first render would parse the whole stream for a result nobody
  # receives, so the read waits for the live connection and is started by the
  # `sync_scope/1` that follows it.
  defp start_load(socket, scope, key) do
    if connected?(socket) do
      opts = load_opts(scope)

      socket
      |> assign(:bo_analytics_key, key)
      |> assign(:bo_analytics_loading?, true)
      |> start_async({:build_order_analytics, key}, fn -> Presenter.load(opts) end)
    else
      socket
    end
  end

  defp load_opts(scope) do
    [
      telemetry_file: Application.get_env(:aiur, :analytics_telemetry_file),
      # A 30-second UI refresh must remain a bounded tail read. Cross-session
      # reporting needs a materialized summary rather than synchronously
      # reparsing every retained telemetry record on each tick.
      session: :current,
      tickets: MapSet.to_list(scope.tickets),
      timeline: :active,
      scope_total: scope.total,
      orchestrator: Endpoint.config(:orchestrator) || Aiur.Orchestrator,
      snapshot_timeout_ms: PollCadence.snapshot_tolerance_ms(Endpoint.config(:snapshot_timeout_ms) || 15_000)
    ]
  end

  defp apply_result(socket, {:ok, model}) do
    socket
    |> assign(:bo_analytics_model, model)
    |> assign(:bo_analytics_unavailable, nil)
  end

  # A newly unavailable stream keeps the last good model rather than blanking a
  # pane the operator was reading; only a first read with nothing to show is empty.
  defp apply_result(socket, {:unavailable, reason}) do
    if socket.assigns.bo_analytics_model do
      socket
    else
      socket |> assign(:bo_analytics_model, nil) |> assign(:bo_analytics_unavailable, reason)
    end
  end

  defp apply_result(socket, _other), do: apply_result(socket, {:unavailable, :error})

  defp stale?(%{assigns: %{bo_analytics_loading?: true}}), do: false
  defp stale?(%{assigns: %{bo_analytics_loaded_at: nil}}), do: false

  defp stale?(%{assigns: %{bo_analytics_loaded_at: at}}),
    do: System.monotonic_time(:millisecond) - at >= @refresh_ms

  # --- identity reset ------------------------------------------------------

  defp reset_on_identity_change(socket, identity) do
    if identity == socket.assigns.bo_analytics_identity do
      socket
    else
      socket
      |> assign(:bo_analytics_identity, identity)
      |> assign(:bo_analytics_model, nil)
      |> assign(:bo_analytics_unavailable, nil)
      |> assign(:bo_analytics_key, nil)
      |> assign(:bo_analytics_loading?, false)
      |> assign(:bo_analytics_loaded_at, nil)
    end
  end

  defp current_identity(route_state) do
    case RouteState.selected_identity(route_state) do
      %TrackerIdentity{} = identity -> TrackerIdentity.github_key(identity)
      _none -> nil
    end
  end
end
