defmodule Aiur.Events.GithubCIPoller.BaseRepair do
  @moduledoc """
  Keeps a polled pull request on its expected base for
  `Aiur.Events.GithubCIPoller`.

  A wrong base is retargeted, and the repair is journaled before and after the
  PATCH so CI recorded against the old base can never validate the new one,
  even across a crash between the two writes.
  """

  require Logger

  alias Aiur.CIApprovalStore
  alias Aiur.GitHub.Client

  @doc false
  @spec ensure_pull_request_base(term(), map(), String.t(), term(), keyword()) ::
          {:ok, :unchanged | {:unchanged, map()} | {:repaired, map()}} | {:error, term(), map() | nil}
  def ensure_pull_request_base(target, pr, head_sha, expected_base, opts) do
    repair_started_at = system_time_seconds(opts)

    repairing = %{
      head_sha: head_sha,
      repaired_at: repair_started_at,
      repair_state: :repairing
    }

    ensure_opts =
      Keyword.put(opts, :before_base_repair_fun, fn ->
        journal_base_repair(target, repairing, opts)
      end)

    case Client.ensure_pull_request_base(pr, expected_base, ensure_opts) do
      {:ok, :unchanged} ->
        recover_interrupted_base_repair(target, pr, head_sha, expected_base, opts)

      {:ok, {:repaired, confirmed_head_sha}} ->
        confirmed = %{
          head_sha: confirmed_head_sha,
          repaired_at: system_time_seconds(opts),
          repair_state: :repaired
        }

        case journal_base_repair(target, confirmed, opts) do
          :ok ->
            {:ok, {:repaired, confirmed}}

          {:error, reason} ->
            {:error,
             repair_error(
               pr,
               expected_base,
               {:confirmed_head_journal_failed, confirmed_head_sha, reason}
             ), repairing}
        end

      {:error, {:pull_request_base_repair_failed, %{repair_journaled: true}} = reason} ->
        {:error, reason, repairing}

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  defp recover_interrupted_base_repair(target, pr, head_sha, expected_base, opts) do
    case base_repair_invalidation(opts, target) do
      %{repair_state: :repairing} = repairing ->
        persist_recovered_base_repair(target, pr, head_sha, expected_base, repairing, opts)

      %{"repair_state" => "repairing"} = repairing ->
        persist_recovered_base_repair(target, pr, head_sha, expected_base, repairing, opts)

      _ ->
        {:ok, :unchanged}
    end
  end

  defp persist_recovered_base_repair(target, pr, head_sha, expected_base, repairing, opts) do
    recovered = %{
      head_sha: head_sha,
      repaired_at: system_time_seconds(opts),
      repair_state: :repaired
    }

    case journal_base_repair(target, recovered, opts) do
      :ok ->
        {:ok, {:unchanged, recovered}}

      {:error, reason} ->
        {:error,
         repair_error(
           pr,
           expected_base,
           {:repair_confirmation_journal_failed, head_sha, reason}
         ), repairing}
    end
  end

  defp base_repair_invalidation(opts, target) do
    opts
    |> Keyword.get(:base_repair_invalidations, %{})
    |> Map.get(to_string(target))
  end

  @doc false
  @spec put_base_repair_invalidation(keyword(), term(), map()) :: keyword()
  def put_base_repair_invalidation(opts, target, invalidation) do
    invalidations = Keyword.get(opts, :base_repair_invalidations, %{})
    Keyword.put(opts, :base_repair_invalidations, Map.put(invalidations, to_string(target), invalidation))
  end

  defp journal_base_repair(target, invalidation, opts) do
    journal_fun =
      Keyword.get(opts, :base_repair_journal_fun, fn target, marker ->
        CIApprovalStore.journal_base_repair(target, marker)
      end)

    try do
      case journal_fun.(to_string(target), invalidation) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_base_repair_journal_result, other}}
      end
    rescue
      error -> {:error, {:base_repair_journal_failed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:base_repair_journal_failed, {kind, reason}}}
    end
  end

  defp repair_error(pr, expected_base, reason) do
    {:pull_request_base_repair_failed,
     %{
       pr_number: Map.get(pr, "number"),
       current_base: get_in(pr, ["base", "ref"]),
       expected_base: expected_base,
       reason: reason,
       repair_journaled: true
     }}
  end

  @doc false
  @spec base_branch_failure(term(), integer(), String.t(), term(), term(), map() | nil) :: map()
  def base_branch_failure(target, pr_number, head_sha, expected_base, reason, invalidation) do
    excerpt = base_branch_failure_message(pr_number, expected_base, reason)

    Logger.warning("GithubCIPoller rejected pull request base: issue=#{target} reason=#{inspect(reason)}")

    result = %{
      target: target,
      pr_number: pr_number,
      head_sha: head_sha,
      decision: :failed,
      failures: [
        %{
          name: "pull request base branch",
          kind: "pull_request",
          result: "repair_failed",
          excerpt: excerpt
        }
      ]
    }

    if is_map(invalidation),
      do: Map.put(result, :base_repair_invalidation, invalidation),
      else: result
  end

  @doc false
  @spec base_branch_repaired(term(), integer(), map(), term()) :: map()
  def base_branch_repaired(target, pr_number, invalidation, expected_base) do
    Logger.warning(
      "GithubCIPoller repaired pull request base: issue=#{target} pr=#{pr_number} " <>
        "expected_base=#{inspect(expected_base)} action=ci_revalidation_required"
    )

    %{
      target: target,
      pr_number: pr_number,
      head_sha: invalidation.head_sha,
      decision: :failed,
      base_repair_invalidation: invalidation,
      failures: [
        %{
          name: "pull request base branch",
          kind: "pull_request",
          result: "repaired",
          excerpt:
            "Pull request ##{pr_number} was retargeted to configured tracker.base_branch " <>
              "#{inspect(expected_base)}. CI recorded before the repair is not valid for the new base; " <>
              "rerun CI or push a follow-up commit, then verify baseRefName before handoff."
        }
      ]
    }
  end

  defp system_time_seconds(opts) do
    opts
    |> Keyword.get(:system_time_fun, fn -> System.system_time(:second) end)
    |> then(& &1.())
  end

  defp base_branch_failure_message(
         pr_number,
         expected_base,
         {:pull_request_base_repair_failed, details}
       ) do
    "Pull request ##{pr_number} targets #{inspect(details.current_base)}; " <>
      "configured tracker.base_branch is #{inspect(expected_base)}. Automatic REST retarget failed: " <>
      "#{inspect(details.reason)}. Retarget only the PR base, then verify baseRefName before retrying CI."
  end

  defp base_branch_failure_message(pr_number, expected_base, reason) do
    "Pull request ##{pr_number} base could not be verified against configured tracker.base_branch " <>
      "#{inspect(expected_base)}: #{inspect(reason)}. " <>
      "Verify baseRefName or retarget only the PR base before retrying CI."
  end
end
