defmodule Aiur.Orchestrator.StatusCLI.StatusTable do
  @moduledoc false
  alias Aiur.Config
  alias Aiur.ControlCLI.DispatchAccount
  alias Aiur.Orchestrator.StatusObservation
  alias Aiur.Orchestrator.StatusReason
  alias Aiur.Orchestrator.WaitingReason
  import Aiur.Orchestrator.ControlCLI.Output, only: [display_identifier: 1]

  @doc false
  @spec print_status_table(term()) :: term()
  def print_status_table([]) do
    IO.puts("ISSUE STATE  TITLE")
    IO.puts("(no active agents)")
  end

  def print_status_table(statuses) do
    IO.puts("ISSUE STATE   TITLE")

    Enum.each(statuses, fn status ->
      IO.puts([
        String.pad_trailing(display_identifier(status), 6),
        " ",
        String.pad_trailing(status_state_label(status), 7),
        " ",
        to_string(status.title || ""),
        status_reason_suffix(status)
      ])
    end)
  end

  defp status_reason_suffix(status) do
    reason = status_reason_detail(status)

    details =
      [
        waiting_reason_detail(status),
        dispatch_decline_detail(status),
        pause_reason_detail(status),
        executor_owner_detail(status),
        blocked_by_detail(status),
        last_failure_detail(status)
      ]
      |> Enum.reject(&is_nil/1)

    reason_suffix = if reason, do: " (#{reason})", else: ""
    details_suffix = if details == [], do: "", else: " [#{Enum.join(details, "; ")}]"
    reason_suffix <> details_suffix <> WaitingReason.render_wait(status) <> StatusObservation.row_label(status) <> DispatchAccount.suffix(status)
  end

  defp status_reason_detail(%{reason: reason}) when not is_nil(reason), do: StatusReason.render(reason)
  defp status_reason_detail(_status), do: nil

  defp status_state_label(%{work_state: work_state}) when work_state in [:starting, :retrying], do: to_string(work_state)
  defp status_state_label(status), do: to_string(status.state)

  defp last_failure_detail(%{last_failure_at: %DateTime{} = at}), do: "last_failure_at=#{DateTime.to_iso8601(at)}"
  defp last_failure_detail(_status), do: nil

  defp waiting_reason_detail(%{waiting_reason: reason}) when not is_nil(reason),
    do: "waiting=#{WaitingReason.render(reason)}"

  defp waiting_reason_detail(_status), do: nil

  defp dispatch_decline_detail(%{dispatch_decline_reason: reason}) when is_atom(reason) and not is_nil(reason),
    do: "dispatch_decline=#{reason}"

  defp dispatch_decline_detail(%{dispatch_decline_reason: reason}) when not is_nil(reason),
    do: "dispatch_decline=#{inspect(reason)}"

  defp dispatch_decline_detail(_status), do: nil

  defp pause_reason_detail(%{pause_reason: reason}) when not is_nil(reason),
    do: "pause_reason=#{reason}"

  defp pause_reason_detail(_status), do: nil

  defp executor_owner_detail(%{executor_owner: owner}) when is_binary(owner) and owner != "",
    do: "executor_owned_by=#{owner}"

  defp executor_owner_detail(_status), do: nil

  defp blocked_by_detail(%{waiting_reason: :waiting_for_dependency, blocked_by: blockers})
       when is_list(blockers) do
    names =
      blockers
      |> Enum.map(
        &(Map.get(&1, :identifier) || Map.get(&1, "identifier") || Map.get(&1, :id) ||
            Map.get(&1, "id"))
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)

    if names == [], do: "blocked_by=unknown", else: "blocked_by=#{Enum.join(names, ",")}"
  end

  defp blocked_by_detail(_status), do: nil

  # The binding signal comes from the daemon; the CLI may run on another host.
  @doc false
  @spec visible_status_row?(term(), term()) :: term()
  def visible_status_row?(%{work_state: :deactivated}, _tracker_states), do: false
  def visible_status_row?(%{work_state: "deactivated"}, _tracker_states), do: false

  # A latched-out agent is idle but terminal: the lifetime dispatch budget is
  # exhausted and will not clear on its own (#1712). Keep the row visible even
  # when the tracker-state filters below would hide it, so `aiur status` shows
  # the state an operator has to act on.
  def visible_status_row?(
        %{state: :idle, reason: {:latched, _lifetime, _maximum}},
        _tracker_states
      ),
      do: true

  # A released claim is an operator-actionable idle state, so it stays visible
  # even when the ticket is outside the active tracker states. It is NOT exempt
  # from the terminal filter: a claim released on a ticket that has since been
  # closed cannot be recovered, and showing it forever is a wrong count (#1475).
  def visible_status_row?(%{state: :idle, reason: {:claim_released, _cause, _retry_in_ms}} = status, tracker_states) do
    not in_tracker_state_set?(Map.get(status, :tracker_state), tracker_states.terminal)
  end

  # An orphaned claim is the exact tracker/runtime contradiction status exists
  # to diagnose. Keep it visible even when a tracker's configured active-state
  # spelling differs from the normalized claim state in the retained row. A
  # post-reconciliation stale claim is the same contradiction and gets the same
  # treatment.
  def visible_status_row?(%{state: :idle, reason: reason} = status, tracker_states)
      when reason in [:orphaned_claim, :stale_claim, :workspace_ownership_waiting, :workspace_retained] do
    not in_tracker_state_set?(Map.get(status, :tracker_state), tracker_states.terminal)
  end

  def visible_status_row?(%{state: :idle, tracker_state: tracker_state}, tracker_states) do
    in_tracker_state_set?(tracker_state, tracker_states.active) and
      not in_tracker_state_set?(tracker_state, tracker_states.terminal)
  end

  def visible_status_row?(%{tracker_state: tracker_state}, tracker_states) do
    not in_tracker_state_set?(tracker_state, tracker_states.terminal)
  end

  def visible_status_row?(_status, _tracker_states), do: true

  defp in_tracker_state_set?(tracker_state, set) when is_binary(tracker_state) do
    MapSet.member?(set, normalized_tracker_state(tracker_state))
  end

  defp in_tracker_state_set?(_tracker_state, _set), do: false

  # Read the configured tracker states ONCE per command. Resolving them per row
  # meant two `Config.settings!/0` reads per agent, and each of those is a
  # `WorkflowStore` GenServer call — nine agents turned one status render into
  # eighteen chances to stall on a saturated daemon (#1684).
  @doc false
  @spec tracker_state_sets() :: term()
  def tracker_state_sets do
    tracker = Config.settings!().tracker

    %{
      active: normalized_tracker_state_set(tracker.active_states),
      terminal: normalized_tracker_state_set(tracker.terminal_states)
    }
  end

  defp normalized_tracker_state_set(states) do
    states
    |> Enum.map(&normalized_tracker_state/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalized_tracker_state(state) when is_binary(state),
    do: String.downcase(String.trim(state))

  defp normalized_tracker_state(_state), do: ""
end
