defmodule AiurWeb.PostDeployLive do
  @moduledoc "Operator checklist for manual checks reported by merged pull requests."

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.PostDeployChecklist
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.{AwaitingCommands, DashboardShell, NavState, Overview, RouteRegistry}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Aiur.PubSub, "post_deploy_checks")

    {:ok,
     socket
     |> DashboardShell.mount()
     |> AwaitingCommands.mount(connected?(socket))
     |> assign(:current_route, post_deploy_route())
     |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
     |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))
     |> assign(:checks, PostDeployChecklist.list())
     |> assign(:checklist_error, checklist_error())}
  end

  @impl true
  def handle_info({:post_deploy_checks_updated, checks}, socket) when is_list(checks),
    do: {:noreply, assign(socket, :checks, checks)}

  def handle_info({:decision_changed, _id, _version}, socket),
    do: {:noreply, AwaitingCommands.refresh(socket)}

  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}
  def handle_info(message, socket), do: DashboardShell.handle_info(message, socket)

  @impl true
  def handle_event("toggle-global-pause", _params, socket), do: {:noreply, DashboardShell.toggle_pause(socket)}
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket), do: {:noreply, NavState.restore(socket, collapsed)}

  def handle_event("post-deploy-done", %{"id" => id}, %{assigns: %{writable: true}} = socket) when is_binary(id) do
    if EndpointConfig.get(:dashboard_writable) == true do
      actor = System.get_env("AIUR_DASHBOARD_USERNAME") || "Executor"

      case PostDeployChecklist.mark_done(id, actor) do
        :ok -> {:noreply, assign(socket, :checks, PostDeployChecklist.list())}
        {:error, _reason} -> {:noreply, assign(socket, :checklist_error, "Could not update the post-deploy checklist.")}
      end
    else
      {:noreply, assign(socket, :writable, false)}
    end
  end

  def handle_event("post-deploy-done", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <DashboardShell.dashboard_shell
      route={@current_route}
      routes={RouteRegistry.routes(AiurWeb.Presenter.analytics_navigation())}
      tracker_kind={@tracker_kind}
      agent_kind={@agent_kind}
      nav_collapsed={@nav_collapsed}
      nav_counts={@nav_counts}
      pause_state={DashboardShell.pause_state(assigns)}
    >
      <:banner><Overview.decisions_banner retained_counts={@retained_counts} navigate /></:banner>
      <section id="post-deploy-page" class="section-card" aria-labelledby="post-deploy-title">
        <h2 id="post-deploy-title">Post-deploy checks</h2>
        <p>Run these manual checks after rebuilding the runtime. Completed checks remain in the history.</p>
        <p :if={@checklist_error} role="alert">{@checklist_error}</p>
        <p :if={@checks == []}>No post-deploy checks have been recorded.</p>
        <article :for={check <- @checks} id={"post-deploy-#{check["id"]}"} class="bo-state-card">
          <p><strong :if={check["operator"]}>Requires: {check["operator"]}</strong></p>
          <p>{display_check_text(check["text"])}</p>
          <p>Submitted in <a :if={check["pr_url"]} href={check["pr_url"]} target="_blank" rel="noreferrer">PR #{check["pr_number"]}</a><span :if={check["pr_author"]}> by {check["pr_author"]}</span>. Review the linked PR before running this check.</p>
          <p :if={check["done_at"]}>Completed by {check["done_by"]} at {check["done_at"]}</p>
          <button :if={is_nil(check["done_at"]) and @writable} type="button" phx-click="post-deploy-done" phx-value-id={check["id"]}>Mark done</button>
          <p :if={is_nil(check["done_at"]) and not @writable}>Mark done is unavailable while the dashboard is read-only.</p>
        </article>
      </section>
    </DashboardShell.dashboard_shell>
    """
  end

  defp kind(fun, fallback) do
    fun.() |> to_string()
  rescue
    _error -> fallback
  end

  defp post_deploy_route do
    %{
      id: :post_deploy,
      label: "Post-deploy",
      icon: "✓",
      description: "Manual checks from merged pull requests.",
      path: "/post-deploy",
      type: :live,
      owner: :post_deploy,
      availability: :available,
      active_actions: [:post_deploy]
    }
  end

  defp checklist_error do
    case PostDeployChecklist.status() do
      :ok -> nil
      {:error, _reason} -> "Post-deploy checklist storage is unavailable. Existing checks may not be visible or recorded."
    end
  rescue
    _error -> "Post-deploy checklist storage is unavailable. Existing checks may not be visible or recorded."
  end

  # Sanitizer stores escaped text to protect event digests. Decode that one
  # storage layer here; HEEx escapes the resulting plain text for this page.
  defp display_check_text(text) when is_binary(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
    |> String.replace("&amp;", "&")
  end

  defp display_check_text(text), do: text
end
