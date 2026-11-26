defmodule AiurWeb.ProjectsHome.Gate do
  @moduledoc "Sends a bare `/` to `/projects` when `dashboard.projects_home` is on. `/build` and any query string stay on Build."
  import Phoenix.LiveView, only: [attach_hook: 4, push_navigate: 2]

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) :: {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :projects_home_gate, :handle_params, &redirect/3)}
  end

  defp redirect(_params, uri, socket) do
    case URI.parse(uri) do
      %URI{path: "/", query: nil} -> if enabled?(), do: {:halt, push_navigate(socket, to: "/projects")}, else: {:cont, socket}
      _ -> {:cont, socket}
    end
  end

  defp enabled?, do: Aiur.Config.settings!().dashboard.projects_home == true
end
