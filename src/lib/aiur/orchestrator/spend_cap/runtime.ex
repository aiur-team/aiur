defmodule Aiur.Orchestrator.SpendCap.Runtime do
  @moduledoc false

  require Logger

  alias Aiur.Orchestrator.SpendCap.Record
  alias Aiur.TrackerIdentity
  alias Aiur.Usage.GroupedScopes
  alias Aiur.Usage.GroupedScopes.Scope
  alias Aiur.UsageAggregate

  @spec running_records([map()]) :: {MapSet.t(), MapSet.t(String.t())}
  def running_records(summaries) do
    Enum.reduce(summaries, {MapSet.new(), MapSet.new()}, fn
      %{status: :running, tracker_identity: %TrackerIdentity{} = identity}, {keys, identifiers} ->
        {put_key(keys, Record.key(identity)), identifiers}

      %{status: :running, identifier: identifier}, {keys, identifiers} when is_binary(identifier) ->
        {keys, MapSet.put(identifiers, identifier)}

      _summary, accumulator ->
        accumulator
    end)
  end

  @spec usage(TrackerIdentity.t()) :: map()
  def usage(identity) do
    UsageAggregate.cells_snapshot()
    |> usage_from_snapshot(identity)
  catch
    :exit, _reason -> %{state: :unavailable}
  end

  @spec snapshot((-> term())) :: map()
  def snapshot(snapshot_fun) do
    case safe_call(snapshot_fun) do
      snapshot when is_map(snapshot) -> snapshot
      _other -> %{state: :unavailable}
    end
  end

  @spec project((map(), TrackerIdentity.t() -> term()), map(), TrackerIdentity.t()) :: map()
  def project(project_fun, snapshot, identity) do
    case safe_call(fn -> project_fun.(snapshot, identity) end) do
      usage when is_map(usage) -> usage
      _other -> %{state: :unavailable}
    end
  end

  @spec usage_from_snapshot(map(), TrackerIdentity.t()) :: map()
  def usage_from_snapshot(%{cells: cells, metadata: metadata} = source, identity)
      when is_map(cells) and is_map(metadata) do
    case Scope.explicit_ticket_set([identity]) do
      {:ok, scope} -> GroupedScopes.project(source, scope, currency: "USD")
      _other -> %{state: :unavailable}
    end
  end

  def usage_from_snapshot(_source, _identity), do: %{state: :unavailable}

  @spec update_partial_attention(map(), term(), Record.t(), pid()) :: map()
  def update_partial_attention(state, key, %Record{state: :active, coverage: coverage} = record, owner) do
    if coverage_status(coverage) == :partial do
      open_partial_attention(state, key, record, owner)
    else
      resolve_partial_attention(state, key, record, owner)
    end
  end

  def update_partial_attention(state, key, record, owner), do: resolve_partial_attention(state, key, record, owner)

  @spec finish_partial_attention(map(), term(), :opened | :resolved, term()) :: map()
  def finish_partial_attention(state, _key, _disposition, :ok), do: state

  def finish_partial_attention(state, key, disposition, result) do
    Logger.warning("spend-cap partial alert failed key=#{inspect(key)} reason=#{inspect(result)}")
    restore_partial_attention(state, key, disposition)
  end

  defp open_partial_attention(state, key, record, owner) do
    if MapSet.member?(state.partial_alerted, key) do
      state
    else
      message = "Spend cap for ticket #{record.identity.identifier} has partial pricing coverage; enforcement uses known USD spend only."

      opts = [
        issue: record.identity.identifier,
        message: message,
        reason: "Unknown pricing or attribution can make the recorded spend lower than actual spend.",
        severity: "warning",
        needs_attention: true
      ]

      state
      |> Map.update!(:partial_alerted, &MapSet.put(&1, key))
      |> start_partial_attention(key, :opened, "ticket.#{record.identity.identifier}.usage.spend_cap_partial", opts, owner)
    end
  end

  defp resolve_partial_attention(state, key, record, owner) do
    if MapSet.member?(state.partial_alerted, key) do
      opts = [
        issue: record.identity.identifier,
        message: "Spend-cap pricing coverage is complete again for ticket #{record.identity.identifier}.",
        reason: "The current usage projection no longer has partial pricing coverage.",
        severity: "info",
        needs_attention: false
      ]

      state
      |> Map.update!(:partial_alerted, &MapSet.delete(&1, key))
      |> start_partial_attention(key, :resolved, "ticket.#{record.identity.identifier}.usage.spend_cap_partial.resolved", opts, owner)
    else
      state
    end
  end

  defp start_partial_attention(state, key, disposition, topic, opts, owner) do
    run = fn -> send(owner, {:spend_cap_partial_alert, key, disposition, safe_call(fn -> state.alert_fun.(topic, opts) end)}) end

    case state.task_start_fun.(run) do
      {:ok, _pid} ->
        state

      :ok ->
        state

      error ->
        Logger.warning("spend-cap partial alert start failed key=#{inspect(key)} reason=#{inspect(error)}")
        restore_partial_attention(state, key, disposition)
    end
  end

  defp restore_partial_attention(state, key, :opened), do: Map.update!(state, :partial_alerted, &MapSet.delete(&1, key))
  defp restore_partial_attention(state, key, :resolved), do: Map.update!(state, :partial_alerted, &MapSet.put(&1, key))

  defp coverage_status(coverage) when is_map(coverage), do: Map.get(coverage, :status) || Map.get(coverage, "status")
  defp coverage_status(_coverage), do: nil
  defp put_key(keys, nil), do: keys
  defp put_key(keys, key), do: MapSet.put(keys, key)

  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
