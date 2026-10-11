defmodule Aiur.Events.GithubWebhook.ReadyTransition do
  @moduledoc false

  @spec record(list(), list(), keyword()) :: :ok
  def record(triples, results, opts) do
    Enum.zip(triples, results)
    |> Enum.each(fn
      {{topic, %{pr: %{"number" => number, "head" => %{"sha" => sha}}}, _}, {_topic, {:ok, _, _}}} ->
        case String.split(topic, ".") do
          ["ticket", ticket, "pr", "ready_for_review"] ->
            case Keyword.get(opts, :orchestrator, Aiur.Orchestrator) do
              pid when is_pid(pid) ->
                send(pid, {:github_pr_ready_transition, ticket, number, sha})

              name when is_atom(name) ->
                if pid = Process.whereis(name), do: send(pid, {:github_pr_ready_transition, ticket, number, sha})

              _ ->
                :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end)
  end
end
