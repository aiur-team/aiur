defmodule Aiur.Events.GithubCIPoller.FailureObservation do
  @moduledoc "Stable failed-check identity for suppressing replayed CI observations."

  @fields [:id, :name, :kind, :result, :started_at, :completed_at, :url]
  @version "ci-failure:v1:"

  @spec handled?(map(), map()) :: boolean()
  def handled?(entry, %{head_sha: head_sha, failures: failures}), do: entry["last_cycle"] == signature(head_sha, failures)

  @spec route(map(), map(), (map() -> map())) :: map()
  def route(result, entry, on_new) do
    if handled?(entry, result),
      do: result |> Map.put(:decision, :pending) |> Map.put(:pending_reason, :ci_recovery) |> Map.put(:recovery, "handled_failure"),
      else: on_new.(result)
  end

  @spec signature(String.t(), [map()]) :: String.t()
  def signature(head_sha, failures) when is_binary(head_sha) and is_list(failures) do
    evidence = failures |> Enum.map(&projection/1) |> Enum.sort()
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({head_sha, evidence}, [:deterministic]))
    @version <> Base.encode16(digest, case: :lower)
  end

  defp projection(failure), do: @fields |> Enum.map(&field(failure, &1)) |> List.to_tuple()
  defp field(failure, key), do: Map.get(failure, key, Map.get(failure, Atom.to_string(key)))
end
