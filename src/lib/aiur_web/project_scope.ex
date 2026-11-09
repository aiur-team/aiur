defmodule AiurWeb.ProjectScope do
  @moduledoc """
  Points each dashboard request at one project's tree, so `Aiur.Orchestrator.server/0`
  resolves that project's Orchestrator instead of the bare name projects mode never
  registers.

  The `project` query parameter selects a running project; with exactly one project
  it is the default. With several projects and no valid selection the request has no
  project, and `unselected?/0` lets a handler say so. Without `projects:` this is a no-op.

  Runs as an endpoint plug and as a LiveView `on_mount` hook. HTTP connection
  processes serve many requests, so every call resets the previous selection.
  """
  @behaviour Plug

  alias Aiur.Project.{Context, Registry}

  @unselected {__MODULE__, :unselected}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: conn |> Plug.Conn.fetch_query_params() |> tap(&select(&1.query_params))

  @spec on_mount(atom(), map() | :not_mounted_at_router, map(), Phoenix.LiveView.Socket.t()) :: {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, _session, socket) do
    select(if is_map(params), do: params, else: %{})
    {:cont, socket}
  end

  @doc "True when several projects run and this request picked none of them."
  @spec unselected?() :: boolean()
  def unselected?, do: Process.get(@unselected, false)

  @doc "The running project ids a request can pick from."
  @spec project_ids() :: [Aiur.Project.id()]
  def project_ids, do: Registry.project_ids()

  defp select(params) do
    Context.delete()
    Process.delete(@unselected)

    case {Registry.project_ids(), params |> Map.get("project") |> normalize()} do
      {[], _requested} -> :ok
      {[only], nil} -> put(only)
      {ids, requested} -> if requested in ids, do: put(requested), else: unselect()
    end
  end

  defp normalize(id) when is_binary(id) and id != "", do: String.downcase(id)
  defp normalize(_id), do: nil

  defp put(id) do
    case Registry.project(id) do
      %Aiur.Project{} = project -> Context.put(project)
      nil -> unselect()
    end
  end

  # A request process has no project lineage, so a deleted Context reads as no project.
  defp unselect, do: Process.put(@unselected, true)
end
