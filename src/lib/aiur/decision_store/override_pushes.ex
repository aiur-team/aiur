defmodule Aiur.DecisionStore.OverridePushes do
  @moduledoc false

  require Logger

  alias Aiur.DecisionStore.CommandFacts
  alias Aiur.Tracker

  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ Aiur.Events.exchange_server()) do
    with :ok <- Aiur.Events.subscribe("ticket.*.branch.push", server),
         do: Aiur.Events.subscribe("ticket.*.pr.merged", server)
  catch
    :exit, reason ->
      detail = Aiur.SecretRedactor.redact(inspect(reason))
      Logger.warning("aiur_decision_store phase=override_push_subscription_failed reason=#{detail}")
      :ok
  end

  @spec ingest(map(), map()) :: map()
  def ingest(state, %{topic: topic, source: :system} = event) do
    case String.split(topic, ".") do
      ["ticket", ticket, "branch", "push"] ->
        remember_push(state, ticket, Map.get(event, :payload, event))

      ["ticket", ticket, "pr", "merged"] ->
        send(self(), {:override_ticket_merged, ticket})
        state

      _other ->
        state
    end
  end

  def ingest(state, _event), do: state

  @doc "A matching pending signal must be journaled before a merged snapshot can settle the override."
  @spec pending?(map(), map()) :: boolean()
  def pending?(state, %{state: :delivered, decision_id: id, action_id: action, delivered_at: %DateTime{} = delivered, ticket: ticket}) do
    with %{sha: sha, ref: ref} <- get_in(state, [:override_pending_pushes, {id, action}]),
         %{pr: %{head_sha: ^sha, head_ref: branch} = pr} <- state.override_context_reader.(ticket.identifier),
         true <- is_binary(branch) and ref == "refs/heads/" <> branch,
         %DateTime{} = pushed <- head_updated_at(pr) do
      DateTime.compare(pushed, delivered) == :gt
    else
      _ -> false
    end
  end

  def pending?(_state, _record), do: false

  defp remember_push(state, ticket, %{sha: sha, ref: "refs/heads/" <> branch} = signal)
       when is_binary(sha) and sha != "" and branch != "" do
    pending = Map.get(state, :override_pending_pushes, %{})
    pending = Enum.reduce(candidates(state, ticket), pending, fn {_ticket, candidate}, acc -> Map.put(acc, candidate_action(candidate), Map.take(signal, [:sha, :ref])) end)
    state = Map.put(state, :override_pending_pushes, pending)
    start_lookup(state, ticket)
    state
  end

  defp remember_push(state, _ticket, _invalid), do: state

  @doc "Rechecks held PR observations; remote merge evidence uses bounded corrective reconciliation."
  @spec reconcile(map()) :: :ok
  def reconcile(state), do: start_lookup(state, :all)

  defp start_lookup(state, ticket) do
    candidates = candidates(state, ticket)

    if candidates != [] do
      owner = self()
      reader = state.override_context_reader
      pending = Map.get(state, :override_pending_pushes, %{})
      {:ok, _pid} = Task.start(fn -> lookup_candidates(owner, reader, candidates, pending) end)
    end

    :ok
  end

  defp candidates(state, ticket) do
    for {_id, decision} <- state.current,
        ticket == :all or decision.ticket.identifier == ticket,
        record <- decision.overrides,
        record.state in [:queued, :delivered, :failed] and record.route in [:active_worker, :resume_pending, :capacity_wait, :replacement],
        is_nil(Map.get(record, :closed_without_merged_pr_at)),
        record.action_id == decision.active_action_id,
        do: {decision.ticket.identifier, {decision.decision_id, record.action_id, Map.get(record, :merge_version, 1)}}
  end

  defp lookup_candidates(owner, reader, candidates, pending) do
    candidates
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {identifier, actions} -> send_lookup(owner, reader, identifier, actions, pending) end)
  end

  defp send_lookup(owner, reader, identifier, actions, pending) do
    case reader.(identifier) do
      %{pr: %{head_sha: sha, head_ref: branch} = pr} when is_binary(sha) and is_binary(branch) ->
        ref = "refs/heads/" <> branch
        matching = Enum.filter(actions, &match?(%{sha: ^sha, ref: ^ref}, Map.get(pending, candidate_action(&1))))
        if matching != [], do: send(owner, {:override_push_observed, matching, sha, ref, head_updated_at(pr), pr})
        if Map.get(pr, :merged?) == true, do: send(owner, {:override_ticket_merged, identifier})

      %{pr: %{merged?: true}} ->
        send(owner, {:override_ticket_merged, identifier})

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
  def context(ticket) do
    case Tracker.ticket_pull_request(ticket) do
      {:ok, pr} when is_map(pr) -> %{pr: pr}
      _ -> %{pr: :unknown}
    end
  end

  @spec settle(map(), list(), String.t(), String.t(), term(), term()) :: map()
  def settle(state, candidates, sha, ref, _observed_at, %{head_sha: sha, head_ref: branch, number: number} = pr)
      when is_binary(branch) and is_integer(number) do
    at = head_updated_at(pr)

    if ref == "refs/heads/" <> branch and match?(%DateTime{}, at) do
      Enum.reduce(candidates, state, fn candidate, acc ->
        {id, action_id} = candidate_action(candidate)
        data = %{action_id: action_id, at: at, head_sha: sha, pr_number: number}

        settle_candidate(acc, id, branch, data, ref)
      end)
      |> clear_pending(candidates, sha, ref)
    else
      state
    end
  end

  def settle(state, _candidates, _sha, _ref, _at, _pr), do: state

  defp clear_pending(%{writable?: false} = state, _candidates, _sha, _ref), do: state

  defp clear_pending(state, candidates, sha, ref) do
    pending =
      Enum.reduce(candidates, Map.get(state, :override_pending_pushes, %{}), fn candidate, acc ->
        key = candidate_action(candidate)
        if Map.get(acc, key) == %{sha: sha, ref: ref}, do: Map.delete(acc, key), else: acc
      end)

    Map.put(state, :override_pending_pushes, pending)
  end

  defp candidate_action({id, action, _version}), do: {id, action}
  defp candidate_action(pair), do: pair

  defp settle_candidate(state, id, branch, data, ref) do
    pending = get_in(state, [:override_pending_pushes, {id, data.action_id}])
    if pending == %{sha: data.head_sha, ref: ref} and same_branch?(state, id, data.action_id, branch), do: record_push(state, id, data), else: state
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
