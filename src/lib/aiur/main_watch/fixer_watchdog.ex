defmodule Aiur.MainWatch.FixerWatchdog do
  @moduledoc false
  alias Aiur.GitHub.{Config, StatePolicy}
  alias Aiur.MainWatch.Fixer

  @spec check([map()], keyword()) :: :ok | {:error, term()}
  def check([], _opts), do: :ok

  def check(issues, opts) do
    now = Keyword.get(opts, :now_fun, fn -> System.system_time(:millisecond) end).()
    snapshot = Keyword.get(opts, :fixer_snapshot, fn -> Aiur.Orchestrator.snapshot() end).()

    Enum.reduce_while(issues, :ok, fn issue, :ok ->
      result = check_issue(issue, snapshot, now, opts)
      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp check_issue(issue, snapshot, now, opts) do
    id = to_string(issue["number"])
    running = if is_map(snapshot), do: Enum.any?(snapshot[:running] || [], &(to_string(&1.issue_id) == id and &1.work_state not in [:paused, :completed, :deactivated])), else: false

    with true <- pending?(issue),
         false <- running,
         {:ok, created, _} <- DateTime.from_iso8601(issue["created_at"] || ""),
         true <- now - DateTime.to_unix(created, :millisecond) >= 300_000 do
      Fixer.once("stalled:#{id}", opts, fn ->
        Fixer.alert("system.main.fixer.stalled", %{issue: id, reason: reason(id, snapshot, issue)}, opts)
      end)
    else
      _ -> :ok
    end
  end

  defp pending?(issue) do
    labels = Enum.map(issue["labels"] || [], &String.downcase(&1["name"]))
    prefix = String.downcase(Config.label_prefix())
    states = Enum.filter(labels, &String.starts_with?(&1, prefix <> ":"))
    StatePolicy.state_label(prefix, "todo") in labels or (states == [] and "needs-triage" in labels)
  end

  defp reason(_id, snapshot, _issue) when not is_map(snapshot), do: :orchestrator_unavailable

  defp reason(id, snapshot, issue) do
    idle = Enum.find(snapshot[:idle] || [], &(to_string(&1.issue_id) == id))

    cond do
      "needs-triage" in Enum.map(issue["labels"] || [], & &1["name"]) -> :authorization
      is_map(idle) and idle[:dispatch_decline_reason] == :unauthorized -> :authorization
      true -> hold_reason(snapshot)
    end
  end

  defp hold_reason(%{dispatch_hold: %{held?: true, reason: reason}}), do: reason || :unknown
  defp hold_reason(%{capacity_hold: %{held?: true, signal: signal}}), do: signal || :unknown
  defp hold_reason(%{globally_paused: true}), do: :global_pause
  defp hold_reason(_snapshot), do: :unknown
end
