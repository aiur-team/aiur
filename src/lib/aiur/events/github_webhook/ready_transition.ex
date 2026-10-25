defmodule Aiur.Events.GithubWebhook.ReadyTransition do
  @moduledoc false

  @spec record(list(), list(), keyword()) :: :ok
  def record(triples, results, opts) do
    Enum.zip(triples, results)
    |> Enum.each(&record_one(&1, opts))
  end

  defp record_one(
         {{topic, %{pr: %{"number" => number, "head" => %{"sha" => sha}}}, _}, {_topic, {:ok, _, _}}},
         opts
       ) do
    case String.split(topic, ".") do
      ["ticket", ticket, "pr", "ready_for_review"] -> notify(Keyword.get(opts, :orchestrator, Aiur.Orchestrator), ticket, number, sha)
      _ -> :ok
    end
  end

  defp record_one(_result, _opts), do: :ok

  defp notify(pid, ticket, number, sha) when is_pid(pid), do: send(pid, {:github_pr_ready_transition, ticket, number, sha})
  defp notify(name, ticket, number, sha) when is_atom(name), do: notify(Process.whereis(name), ticket, number, sha)
  defp notify(_name, _ticket, _number, _sha), do: :ok
end
