defmodule Aiur.DecisionAttentionResolution do
  @moduledoc false

  alias Aiur.{AlertFeed, DecisionStore}

  @spec pid_alive?(pos_integer()) :: boolean()
  def pid_alive?(pid) when is_integer(pid) and pid > 0 do
    case :os.type() do
      {:unix, :linux} -> proc_pid_alive?(pid)
      {:unix, :darwin} -> ps_pid_alive?(pid)
      _ -> true
    end
  rescue
    _error -> true
  end

  defp proc_pid_alive?(pid) do
    case File.read("/proc/#{pid}/status") do
      {:ok, status} ->
        case Regex.run(~r/^State:\s+(\w)/m, status, capture: :all_but_first) do
          [state] -> process_state_alive?(state)
          _ -> true
        end

      {:error, :enoent} ->
        false

      {:error, _reason} ->
        ps_pid_alive?(pid)
    end
  end

  @doc false
  @spec ps_pid_alive?(pos_integer()) :: boolean()
  def ps_pid_alive?(pid) do
    case System.find_executable("ps") do
      nil ->
        true

      ps ->
        case System.cmd(ps, ["-p", Integer.to_string(pid), "-o", "stat="], stderr_to_stdout: true) do
          {output, 0} -> process_state_alive?(String.trim(output))
          {output, _status} -> String.trim(output) != ""
        end
    end
  end

  @doc false
  @spec process_state_alive?(String.t()) :: boolean()
  def process_state_alive?(<<state::binary-size(1), _rest::binary>>), do: state != "Z"
  def process_state_alive?(_state), do: false

  @spec acknowledged?(String.t()) :: boolean()
  def acknowledged?(topic), do: AlertFeed.condition_state(topic) == :resolved

  @spec resolve?(map(), map()) :: boolean()
  def resolve?(attention, state) do
    stale_condition?(attention, state) or duplicate_dispatch_cleared?(attention, state) or
      answered_operator_decision?(attention, state) or owner_status(attention, state) == :owner
  end

  defp duplicate_dispatch_cleared?(
         %{slug: "duplicate-dispatch", question: question, issue: %{identifier: identifier}} =
           attention,
         state
       ) do
    topic = "ticket.#{identifier}.agent.attention.duplicate-dispatch"
    acknowledged? = state.attention_acknowledged?.(topic)

    if acknowledged? do
      acknowledged?
    else
      pid_state_known? =
        is_nil(Map.get(attention, :worker_host)) and
          not Map.get(attention, :restored?, false)

      if pid_state_known? do
        pids = Regex.scan(~r/\bpid\s+(\d+)\b/, question, capture: :all_but_first) |> List.flatten()
        pids != [] and Enum.count(pids, &state.pid_alive?.(String.to_integer(&1))) <= 1
      else
        false
      end
    end
  end

  defp duplicate_dispatch_cleared?(_attention, _state), do: false

  @spec owner_status(map(), map()) :: :owner | :none | :unknown | :not_applicable
  def owner_status(%{slug: "stranded-requeued", issue: %{identifier: identifier}}, %{
        owner_lookup: lookup
      })
      when is_function(lookup, 1) do
    case lookup.(identifier) do
      true -> :owner
      false -> :none
      _unknown -> :unknown
    end
  end

  def owner_status(_attention, _state), do: :not_applicable

  defp stale_condition?(%{slug: slug, opened_at: %DateTime{} = opened_at}, state) do
    condition_attention?(slug) and
      DateTime.diff(state.now_fun.(), opened_at, :millisecond) >= state.condition_attention_ttl_ms
  end

  defp stale_condition?(_attention, _state), do: false

  defp answered_operator_decision?(
         %{slug: "operator-decision", issue: %{identifier: identifier}},
         state
       ) do
    state.decision_store
    |> DecisionStore.list()
    |> Enum.all?(fn decision ->
      decision.ticket.identifier != identifier or
        decision.decision_status not in [:open, :deferred]
    end)
  end

  defp answered_operator_decision?(_attention, _state), do: false

  defp condition_attention?(slug) do
    base_branch = Aiur.Config.base_branch()
    branch_red = "#{base_branch}-red"
    branch_ci_red = "#{base_branch}-ci-red"
    detailed_ci_red_prefix = branch_ci_red <> "-"

    slug in [branch_red, branch_ci_red] or
      (String.starts_with?(slug, detailed_ci_red_prefix) and
         byte_size(slug) > byte_size(detailed_ci_red_prefix))
  end
end
