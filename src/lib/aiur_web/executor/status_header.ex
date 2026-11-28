defmodule AiurWeb.Executor.StatusHeader do
  @moduledoc "Full and compact presentations of the shared Executor snapshot."
  use Phoenix.Component

  alias Aiur.Instance.Roster.Presentation

  attr(:snapshot, :any, required: true)
  attr(:compact, :boolean, default: false)
  attr(:retry, :string, default: nil)

  @spec header(map()) :: Phoenix.LiveView.Rendered.t()
  def header(%{snapshot: snapshot} = assigns) when snapshot in [:loading, :unavailable] do
    ~H"""
    <span :if={@snapshot == :loading} role="status">Loading Executor status…</span>
    <span :if={@snapshot == :unavailable} class="executor-status__activity" data-state="unavailable" role="status">Executor status unavailable</span>
    <button :if={@snapshot == :unavailable && @retry} type="button" phx-click={@retry}>Retry</button>
    """
  end

  def header(assigns) do
    snapshot = assigns.snapshot
    state = activity(snapshot)

    assigns =
      assign(assigns,
        state: state,
        observation: observation(state, snapshot.harness_state),
        command_link?: state == :waiting_for_input && open_commands?(snapshot.blockers)
      )

    ~H"""
    <span class="executor-status__activity" data-state={@state} data-freshness={@observation.freshness}>
      <strong role={if @compact, do: "status"}>{label(@state)}</strong><%= if @observation.at do %><%= if @state == :unknown, do: ", last seen ", else: " · last heard " %><time
          datetime={DateTime.to_iso8601(@observation.at)}
          title={DateTime.to_iso8601(@observation.at)}
        >{Presentation.age(@observation.age_ms)} ago</time><% end %>
      <small :if={@state == :unknown && !@observation.at}> · last seen time unknown</small>
      <small :if={@observation.freshness == :stale}> · stale</small>
      <small :if={not @compact && @observation.freshness == :fresh}> · fresh</small>
    </span>
    <a :if={not @compact && @command_link?} href="/commands?requester=executor">Open Executor Commands</a>
    <dl :if={not @compact} class="executor-status__details">
      <dt>Harness</dt>
      <dd>{harness(@snapshot.binding, @snapshot.read_capability)}</dd>
      <dt>Read capability</dt>
      <dd>{capability(@snapshot.read_capability)}</dd>
      <dt>Wakes</dt>
      <dd>{wakes(@snapshot.wakes)}</dd>
      <dt>Roster</dt>
      <dd>{roster(@snapshot.roster)}</dd>
    </dl>
    """
  end

  defp activity(%{binding: nil}), do: :not_attached
  defp activity(%{binding: :unavailable}), do: :unavailable
  defp activity(%{binding: %{state: "detached"}}), do: :ended
  defp activity(%{binding: %{state: "awaiting_first_hook"}}), do: :awaiting_hook
  defp activity(%{harness_state: :unavailable}), do: :unavailable
  defp activity(%{harness_state: %{state: state}}), do: state

  defp observation(state, _harness) when state in [:not_attached, :awaiting_hook], do: %{at: nil, age_ms: nil, freshness: :unknown}
  defp observation(_state, :unavailable), do: %{at: nil, age_ms: nil, freshness: :unavailable}
  defp observation(_state, harness), do: %{at: harness.observed_at, age_ms: harness.age_ms, freshness: harness.freshness}

  defp label(:not_attached), do: "Not attached"
  defp label(:awaiting_hook), do: "Waiting for the Executor session"
  defp label(:working), do: "Working"
  defp label(:waiting_for_input), do: "Waiting for input"
  defp label(:idle), do: "Idle"
  defp label(:ended), do: "Ended"
  defp label(:unavailable), do: "Status unavailable"
  defp label(:unknown), do: "Status unknown"

  defp open_commands?(%{items: items}), do: Enum.any?(items, &(&1.kind == :command))
  defp open_commands?(:unavailable), do: false

  defp harness(:unavailable, _capability), do: "unavailable"
  defp harness(nil, _capability), do: "Not attached"

  defp harness(binding, capability) do
    version = Map.get(binding, :codex_cli_version) || (is_map(capability) && capability.cli_version)
    "#{binding.harness} · CLI #{version || "unknown"}"
  end

  defp capability(:unavailable), do: "unavailable"
  defp capability(%{status: status, reason: nil}), do: to_string(status)
  defp capability(%{status: status, reason: reason}), do: "#{status} (#{reason})"

  defp wakes(:unavailable), do: "unavailable"
  defp wakes(%{cursor: cursor, pending_count: pending}), do: "Cursor #{cursor} · #{pending} pending"

  defp roster(:unavailable), do: "unavailable"

  defp roster(rows) do
    owner = Enum.find(rows, &(&1.role == "owner" && &1.state != :expired))
    "#{length(rows)} · Owner #{if owner, do: owner.id, else: "none"}"
  end
end
