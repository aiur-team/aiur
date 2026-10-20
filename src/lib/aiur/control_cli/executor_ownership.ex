defmodule Aiur.ControlCLI.ExecutorOwnership do
  @moduledoc false

  alias Aiur.{Config, GitHub.Labels, Issue, Tracker}
  alias Aiur.Orchestrator.TicketTransition
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2, control_error: 1]

  @spec take([String.t()], String.t()) :: :ok
  def take(targets, owner), do: update(targets, :add, "take", owner)

  @spec release([String.t()], String.t()) :: :ok
  def release(targets, owner), do: update(targets, :remove, "release", owner)

  defp update(targets, action, verb, requested_owner) do
    guarded(verb, fn ->
      owner = normalize_owner(requested_owner)

      label =
        Labels.executor_label_prefix(Config.settings!().tracker.github.label_prefix) <> owner

      results = Enum.map(targets, &write_marker(&1, action, label))
      Enum.each(results, &report(&1, verb, owner))
      exit_marker(if Enum.any?(results, &match?({:error, _}, &1)), do: 1, else: 0)
    end)
  end

  defp write_marker(id, action, label) do
    case Tracker.fetch_issue_states_by_ids([to_string(id)]) do
      {:ok, [issue]} -> write_resolved_marker(issue, id, action, label)
      {:ok, []} -> {id, {:error, :issue_not_found}}
      {:error, reason} -> {id, {:error, reason}}
    end
  end

  defp write_resolved_marker(issue, id, action, label) do
    current = executor_labels(issue)
    result = ensure_marker_label(label, action, issue.identifier, current)
    {id, result}
  end

  defp ensure_marker_label(label, :add, identifier, current) do
    case Enum.find(current, &(&1 != label and String.contains?(&1, ":executor:"))) do
      nil ->
        with :ok <- Tracker.ensure_labels([label]) do
          replace_owner_marker(identifier, current, label, :add)
        end

      _other_owner ->
        {:error, :not_owner}
    end
  end

  defp ensure_marker_label(label, action, identifier, current),
    do: replace_owner_marker(identifier, current, label, action)

  defp replace_owner_marker(identifier, _current, desired, :add),
    do: TicketTransition.write_marker(identifier, :add, desired, writer: :executor_ownership)

  defp replace_owner_marker(identifier, current, desired, :remove) do
    if desired in current do
      TicketTransition.write_marker(identifier, :remove, desired, writer: :executor_ownership)
    else
      {:error, :not_owner}
    end
  end

  defp executor_labels(issue) do
    prefix = Labels.executor_label_prefix(Config.settings!().tracker.github.label_prefix)
    bare_label = String.trim_trailing(prefix, ":")

    Enum.filter(
      Issue.label_names(issue),
      &(String.downcase(&1) == String.downcase(bare_label) or
          String.starts_with?(String.downcase(&1), String.downcase(prefix)))
    )
  end

  defp report({id, :ok}, "take", owner), do: IO.puts("aiur: ticket ##{id} held by #{owner}")

  defp report({id, :ok}, "release", _owner),
    do: IO.puts("aiur: Executor hold released for ##{id}")

  defp report({id, {:error, :not_owner}}, verb, owner),
    do: control_error("aiur: cannot #{verb} ##{id}; it is owned by another Executor, not #{owner}")

  defp report({id, {:error, reason}}, verb, _owner),
    do: control_error("aiur: could not #{verb} ##{id}: #{inspect(reason)}")

  defp normalize_owner(requested) when is_binary(requested) do
    owner =
      requested
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim("-")
      |> String.slice(0, 30)

    if owner == "", do: "executor", else: owner
  end

  defp normalize_owner(_requested), do: "executor"
end
