defmodule Aiur.Ownership.Migration do
  @moduledoc """
  `aiur ownership migrate`: turn today's `agent:<state>` / `nuc:<state>` labels into ownership records.

  `plan/2` is pure. A ticket is claimed only when its *state* labels (`<prefix>:<known state>`)
  name exactly one mapped prefix; `agent:parked`, `agent:queued` and other non-state labels never
  count. `apply/2` claims through `Aiur.Ownership.GitHubRef` (create-if-absent compare-and-set,
  every write paced by the GitHub budget broker); a loss or unknown outcome is reported, never
  retried or inferred.
  """

  alias Aiur.GitHub.StateLabels

  @type owner :: %{state: String.t(), gateway_id: String.t(), gateway_label: String.t()} | nil
  @type ticket :: %{ticket: String.t(), labels: [String.t()], owner: owner()}
  @type action ::
          {:claim, String.t(), String.t()}
          | {:already, String.t(), String.t()}
          | {:conflict, String.t(), [labelled: String.t(), owner: String.t()]}
          | {:ambiguous, String.t(), [String.t()]}
          | {:skip, String.t(), :no_state_label}

  @doc "One action per input ticket, in order. `map` is `%{prefix => gateway}`."
  @spec plan([ticket()], %{String.t() => String.t()}) :: [action()]
  def plan(tickets, map) do
    map = Map.new(map, fn {prefix, gateway} -> {norm(prefix), gateway} end)
    Enum.map(tickets, &plan_one(&1, map))
  end

  defp plan_one(%{ticket: t, labels: labels} = ticket, map) do
    prefixes = labels |> Enum.flat_map(&state_prefix/1) |> Enum.filter(&Map.has_key?(map, &1)) |> Enum.uniq() |> Enum.sort()

    case prefixes do
      [] -> {:skip, t, :no_state_label}
      [prefix] -> decide(t, Map.fetch!(map, prefix), ticket[:owner])
      many -> {:ambiguous, t, many}
    end
  end

  defp decide(t, gateway, nil), do: {:claim, t, gateway}
  defp decide(t, gateway, %{state: "released"}), do: {:claim, t, gateway}

  defp decide(t, gateway, %{gateway_id: id, gateway_label: label}) do
    if norm(gateway) in [norm(id), norm(label)], do: {:already, t, gateway}, else: {:conflict, t, labelled: gateway, owner: label}
  end

  defp state_prefix(label) do
    case label |> norm() |> String.split(":", parts: 2) do
      [prefix, state] -> if state in StateLabels.known_states(), do: [prefix], else: []
      _ -> []
    end
  end

  defp norm(s), do: s |> String.trim() |> String.downcase()

  @doc """
  Performs the `:claim` actions one at a time with `opts[:claim_fun].(ticket, gateway)`, returning
  `{:won, _} | {:lost, _} | {:unknown, _}`. Only `:won` is a write.
  """
  @spec apply([action()], keyword()) :: map()
  def apply(actions, opts) do
    claim_fun = Keyword.fetch!(opts, :claim_fun)
    zero = %{claimed: 0, already: 0, lost: 0, unknown: 0, conflict: 0, ambiguous: [], skipped: 0, writes: 0}
    Enum.reduce(actions, zero, &tally(&1, &2, claim_fun))
  end

  defp tally({:claim, t, gateway}, acc, claim_fun) do
    case claim_fun.(t, gateway) do
      {:won, _} -> %{acc | claimed: acc.claimed + 1, writes: acc.writes + 1}
      {:lost, _} -> %{acc | lost: acc.lost + 1}
      {:unknown, _} -> %{acc | unknown: acc.unknown + 1}
    end
  end

  defp tally({:already, _, _}, acc, _), do: %{acc | already: acc.already + 1}
  defp tally({:conflict, _, _}, acc, _), do: %{acc | conflict: acc.conflict + 1}
  defp tally({:ambiguous, t, prefixes}, acc, _), do: %{acc | ambiguous: acc.ambiguous ++ [{t, prefixes}]}
  defp tally({:skip, _, _}, acc, _), do: %{acc | skipped: acc.skipped + 1}
end
