defmodule Aiur.DecisionStore.OverridePushes do
  @moduledoc false

  require Logger

  alias Aiur.Commands.OverrideContext
  alias Aiur.DecisionStore.CommandFacts

  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ Aiur.Events.exchange_server()) do
    Aiur.Events.subscribe("ticket.*.branch.push", server)
  catch
    :exit, reason ->
      detail = Aiur.SecretRedactor.redact(inspect(reason))
      Logger.warning("aiur_decision_store phase=override_push_subscription_failed reason=#{detail}")
      :ok
  end

  @spec observe(map(), map()) :: :ok
  def observe(state, %{topic: topic, source: :system}) do
    case String.split(topic, ".") do
      ["ticket", ticket, "branch", "push"] -> start_lookup(state, ticket)
      _other -> :ok
    end
  end

  def observe(_state, _event), do: :ok

  @doc "Rechecks replayed delivery records against held PR evidence, without fetching GitHub."
  @spec reconcile(map()) :: :ok
  def reconcile(state), do: start_lookup(state, :all)

  defp start_lookup(state, ticket) do
    candidates =
      for {_id, decision} <- state.current,
          ticket == :all or decision.ticket.identifier == ticket,
          record <- decision.overrides,
          record.state == :delivered and record.route in [:active_worker, :resume_pending, :capacity_wait],
          record.action_id == decision.active_action_id,
          do: {decision.ticket.identifier, {decision.decision_id, record.action_id}}

    if candidates != [] do
      owner = self()
      reader = state.override_context_reader

      {:ok, _pid} = Task.start(fn -> lookup_candidates(owner, reader, candidates) end)
    end

    :ok
  end

  defp lookup_candidates(owner, reader, candidates) do
    candidates
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {identifier, actions} -> send_lookup(owner, reader, identifier, actions) end)
  end

  defp send_lookup(owner, reader, identifier, actions) do
    case reader.(identifier) do
      %{pr: %{head_sha: sha, head_ref: branch} = pr} when is_binary(sha) and is_binary(branch) ->
        send(owner, {:override_push_observed, actions, sha, "refs/heads/" <> branch, head_updated_at(pr), pr})

      _unknown ->
        :ok
    end
  rescue
    error -> lookup_failed(identifier, {:exception, error.__struct__, Exception.message(error)})
  catch
    kind, reason -> lookup_failed(identifier, {kind, reason})
  end

  defp lookup_failed(identifier, reason) do
    detail = Aiur.SecretRedactor.redact(inspect(reason))
    Logger.warning("aiur_decision_store phase=override_push_lookup_failed ticket=#{identifier} reason=#{detail}")
    :ok
  end

  @spec context(String.t()) :: map()
  def context(ticket), do: ticket |> OverrideContext.options([]) |> Keyword.fetch!(:override_context)

  @spec settle(map(), list(), String.t(), String.t(), term(), term()) :: map()
  def settle(state, candidates, sha, ref, _observed_at, %{head_sha: sha, head_ref: branch, number: number} = pr)
      when is_binary(branch) and is_integer(number) do
    at = head_updated_at(pr)

    if ref == "refs/heads/" <> branch and match?(%DateTime{}, at) do
      Enum.reduce(candidates, state, fn {id, action_id}, acc ->
        data = %{action_id: action_id, at: at, head_sha: sha, pr_number: number}
        settle_candidate(acc, id, branch, data)
      end)
    else
      state
    end
  end

  def settle(state, _candidates, _sha, _ref, _at, _pr), do: state

  defp settle_candidate(state, id, branch, data) do
    if same_branch?(state, id, data.action_id, branch), do: record_push(state, id, data), else: state
  end

  defp same_branch?(state, id, action_id, branch) do
    with %{overrides: overrides} <- Map.get(state.current, id),
         record when is_map(record) <- Enum.find(overrides, &(&1.action_id == action_id)) do
      is_nil(record.pr_head_ref) or record.pr_head_ref == branch
    else
      _missing -> false
    end
  end

  defp record_push(state, id, data) do
    case CommandFacts.record(state, id, :override_implemented, data, now: data.at) do
      {:reply, {:ok, _result}, next} ->
        next

      {:reply, {:error, {:invalid_transition, :override_push_mismatch}}, next} ->
        next

      {:reply, {:error, reason}, next} ->
        Logger.warning("aiur_decision_store phase=override_push_append_failed decision_id=#{id} reason=#{inspect(reason)}")
        next
    end
  end

  # A generic PR updated_at can advance for reviews without a push.
  defp head_updated_at(%{head_updated_at: %DateTime{} = at}), do: at

  defp head_updated_at(%{head_updated_at: at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> parsed
      _invalid -> nil
    end
  end

  defp head_updated_at(_pr), do: nil
end
