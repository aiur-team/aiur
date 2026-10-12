defmodule Aiur.OptimisticStart do
  @moduledoc "Validated blocker heads evaluated when an optimistic worker starts."

  alias Aiur.TicketBranch

  @type blocker :: %{identifier: String.t(), pr_number: pos_integer() | nil, ref: String.t(), sha: String.t()}
  @type t :: %{blockers: [blocker()], primary: String.t() | nil, pr_base: String.t() | :base_branch, started_at: DateTime.t()}

  @spec from_gate_evidence([map()], (String.t() -> map() | nil)) :: {:ok, t() | nil} | {:error, :optimistic_ref_unavailable}
  def from_gate_evidence([], _lookup), do: {:ok, nil}

  def from_gate_evidence(blockers, lookup) do
    blockers
    |> Enum.reduce_while({:ok, []}, fn evidence, {:ok, acc} ->
      case blocker(evidence, lookup) do
        {:ok, blocker} -> {:cont, {:ok, [blocker | acc]}}
        :error -> {:halt, {:error, :optimistic_ref_unavailable}}
      end
    end)
    |> build_record()
  end

  @spec valid_head?(term()) :: boolean()
  def valid_head?(%{ref: ref, sha: sha}) do
    is_binary(TicketBranch.ticket_id_from_ref(ref)) and
      is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/i, sha)
  end

  def valid_head?(_head), do: false

  @spec start_point(t() | nil) :: %{ref: String.t(), sha: String.t()} | nil
  def start_point(%{primary: id, blockers: [%{identifier: id} = blocker]}) when is_binary(id) do
    if valid_blocker_head?(blocker, id), do: Map.take(blocker, [:ref, :sha])
  end

  def start_point(_record), do: nil

  defp blocker(evidence, lookup) do
    identifier = to_string(Map.get(evidence, :identifier) || "")
    head = %{ref: full_ref(Map.get(evidence, :head_ref)), sha: Map.get(evidence, :head_sha)}
    head = if valid_blocker_head?(head, identifier), do: head, else: lookup.(identifier)

    if valid_blocker_head?(head, identifier) do
      {:ok, %{identifier: identifier, pr_number: Map.get(evidence, :pr_number), ref: head.ref, sha: String.downcase(head.sha)}}
    else
      :error
    end
  end

  defp valid_blocker_head?(head, identifier) do
    valid_head?(head) and TicketBranch.ticket_id_from_ref(head.ref) == identifier
  end

  defp full_ref("refs/heads/" <> _branch = ref), do: ref
  defp full_ref(branch) when is_binary(branch), do: "refs/heads/" <> branch
  defp full_ref(_branch), do: nil

  defp build_record({:ok, reversed}) do
    blockers = Enum.reverse(reversed)

    {primary, pr_base} =
      case blockers do
        [blocker] -> {blocker.identifier, blocker.ref}
        _ -> {nil, :base_branch}
      end

    {:ok, %{blockers: blockers, primary: primary, pr_base: pr_base, started_at: DateTime.utc_now()}}
  end

  defp build_record(error), do: error
end
