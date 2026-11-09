defmodule AiurWeb.ProjectScope do
  @moduledoc """
  Points each dashboard request at one project's tree, so `Aiur.Orchestrator.server/0`
  resolves that project's Orchestrator instead of the bare name projects mode never
  registers.

  The `project` query parameter picks a running project and the session remembers it
  for the rest of the visit; with exactly one project it is the default. With several
  projects and no pick, or a pick naming no running project, the request has no
  project: project-scoped API handlers answer through `call(conn, :required)` and
  project-scoped LiveViews redirect to `/projects` to pick one. Without `projects:`
  this is a no-op.

  Runs as an endpoint plug and as a LiveView `on_mount` hook. A picked process also
  registers itself under the project in `Aiur.ProjectRegistry`, so every task it
  starts (`start_async`, `Task.async`) resolves the same project through its
  `$callers`. HTTP connection processes serve many requests, so every call resets
  the previous selection and registration.
  """
  @behaviour Plug

  import Plug.Conn

  alias Aiur.Project.{Context, Registry}

  @status {__MODULE__, :status}
  @registered {__MODULE__, :registered}
  @session_key "aiur_project"
  # Machine-level pages that render without a project; every other dashboard page reads one.
  @machine_views [AiurWeb.ProjectsHomeLive, AiurWeb.GatewayLive, AiurWeb.InstanceRosterLive]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, :required) do
    case status() do
      nil -> conn
      status -> conn |> put_status(http_status(status)) |> Phoenix.Controller.json(error_body(status)) |> halt()
    end
  end

  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    requested = normalize(conn.query_params["project"])

    # Only an explicit pick is remembered, so a later second project never inherits the one-project default.
    case select(requested, normalize(get_session(conn, @session_key))) do
      {:picked, ^requested} -> put_session(conn, @session_key, requested)
      _other -> conn
    end
  end

  @spec on_mount(atom(), map() | :not_mounted_at_router, map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, session, socket) do
    requested = if is_map(params), do: normalize(params["project"])
    select(requested, normalize(session[@session_key]))

    case status() do
      nil -> {:cont, socket}
      _status when socket.view in @machine_views -> {:cont, socket}
      status -> {:halt, Phoenix.LiveView.redirect(socket, to: "/projects?" <> URI.encode_query(pick_query(status)))}
    end
  end

  @doc "Why this request has no project: `nil` when it has one or projects mode is off."
  @spec status() :: nil | :unselected | {:unknown, String.t()}
  def status, do: Process.get(@status)

  @doc "The running project ids a request can pick from."
  @spec project_ids() :: [Aiur.Project.id()]
  def project_ids, do: Registry.project_ids()

  defp select(requested, remembered) do
    Context.delete()
    Process.delete(@status)
    unregister()
    ids = Registry.project_ids()

    cond do
      ids == [] -> :none
      requested != nil -> if requested in ids, do: put(requested), else: unselect({:unknown, requested})
      remembered in ids -> put(remembered)
      match?([_only], ids) -> put(hd(ids))
      true -> unselect(:unselected)
    end
  end

  defp normalize(id) when is_binary(id) and id != "", do: String.downcase(id)
  defp normalize(_id), do: nil

  defp put(id) do
    case Registry.project(id) do
      %Aiur.Project{} = project ->
        Context.put(project)
        register(id)
        {:picked, id}

      nil ->
        unselect({:unknown, id})
    end
  end

  # `Context` resolves a task's project from any lineage pid registered as `{id, _}`; only `:root` keys list projects.
  defp register(id) do
    key = {id, {__MODULE__, self()}}
    {:ok, _owner} = Elixir.Registry.register(Aiur.ProjectRegistry, key, nil)
    Process.put(@registered, key)
  end

  defp unregister do
    if key = Process.delete(@registered), do: Elixir.Registry.unregister(Aiur.ProjectRegistry, key)
  end

  # A request process has no project lineage, so a deleted Context reads as no project.
  defp unselect(status) do
    Process.put(@status, status)
    status
  end

  defp http_status(:unselected), do: 409
  defp http_status({:unknown, _id}), do: 404

  defp error_body(:unselected),
    do: %{error: %{code: "project_required", message: "Several projects are running; pick one with ?project=<owner/repo>"}, projects: project_ids()}

  defp error_body({:unknown, id}),
    do: %{error: %{code: "unknown_project", message: "No running project is named #{id}"}, project: id, projects: project_ids()}

  defp pick_query(:unselected), do: [pick: "required"]
  defp pick_query({:unknown, id}), do: [pick: "unknown", unknown: id]
end
