defmodule Aiur.Executor.TakeoverAlert.Snapshot do
  @moduledoc """
  Real-data provider for the Executor takeover alert monitor.

  `fetch/1` enumerates the nonterminal tickets in the configured run scope —
  the union of the current-run membership's nonterminal members and the
  orchestrator's currently-running identifiers — with each ticket's live-owner
  state. `fetch_open_pr/1` best-effort enriches a ticket with open-PR evidence
  (number, creation/push time, mergeability, and — for already-alerted tickets
  only — head CI state), so the alert carries actionable convergence evidence
  without hammering the tracker.

  Every tracker call is fault-isolated: a GitHub outage or a non-GitHub
  tracker degrades to `nil` evidence rather than crashing the monitor tick.
  """

  alias Aiur.{CurrentRunMembership, Orchestrator}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.PullRequests

  @spec fetch(DateTime.t()) :: [map()]
  def fetch(_now) do
    running = running_identifiers()

    identifiers = in_scope_nonterminal_identifiers(running)

    Enum.map(identifiers, fn identifier ->
      %{
        identifier: identifier,
        terminal?: false,
        in_scope?: true,
        live_owner?: Map.has_key?(running, identifier)
      }
    end)
  end

  # A set (map of identifier => true) of the in-scope nonterminal tickets: the
  # union of the current-run membership's nonterminal members and the
  # orchestrator's currently-running identifiers. Plain maps, not MapSet, so the
  # fault-isolated builders below never leak an unproven opaque term to callers.
  defp in_scope_nonterminal_identifiers(running) do
    Map.merge(membership_nonterminal_identifiers(), running)
  end

  defp membership_nonterminal_identifiers do
    case CurrentRunMembership.snapshot() do
      %{members: members} when is_list(members) ->
        members
        |> Enum.reject(&Map.get(&1, :terminal?, false))
        |> Enum.map(&get_in(&1, [:identity, :identifier]))
        |> Enum.reject(&is_nil/1)
        |> Map.new(&{&1, true})

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp running_identifiers do
    Orchestrator.list_running_active_identifiers(Orchestrator, 1_000)
    |> Map.new(&{&1, true})
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  @doc """
  Best-effort open-PR evidence for a ticket, or `nil` when no open PR exists or
  the tracker is unavailable. `opts` forwards to the GitHub client so tests can
  inject a `request_fun`.
  """
  @spec fetch_open_pr(map(), keyword()) :: map() | nil
  def fetch_open_pr(ticket, opts \\ [])

  def fetch_open_pr(%{identifier: identifier} = ticket, opts) do
    case GitHubClient.fetch_open_pull_request_for_branch(identifier, opts) do
      {:ok, pr} when is_map(pr) and map_size(pr) > 0 ->
        %{
          number: Map.get(pr, "number"),
          created_at: parse_timestamp(Map.get(pr, "created_at")),
          pushed_at: parse_timestamp(Map.get(pr, "pushed_at")),
          mergeable_state: Map.get(pr, "mergeable_state"),
          ci_state: maybe_ci_state(pr, ticket, opts)
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def fetch_open_pr(_ticket, _opts), do: nil

  defp maybe_ci_state(pr, %{enrich_ci?: true}, opts) do
    head_sha = get_in(pr, ["head", "sha"])

    if is_binary(head_sha) and head_sha != "" do
      ci_state_for_sha(head_sha, opts)
    end
  end

  defp maybe_ci_state(_pr, _ticket, _opts), do: nil

  defp ci_state_for_sha(sha, opts) do
    case PullRequests.fetch_commit_ci_status(sha, opts) do
      {:ok, %{check_runs: check_runs}} when is_list(check_runs) -> summarize_check_runs(check_runs)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp summarize_check_runs(check_runs) when is_list(check_runs) do
    statuses = Enum.map(check_runs, &Map.get(&1, "status"))
    conclusions = Enum.map(check_runs, &Map.get(&1, "conclusion"))
    failing = Enum.count(conclusions, &(&1 in ["failure", "timed_out", "action_required"]))

    cond do
      failing > 0 -> "failing (#{failing} check#{if(failing == 1, do: "", else: "s")})"
      conclusions != [] and Enum.all?(conclusions, &(&1 == "success")) -> "success"
      Enum.any?(statuses, &(&1 in ["queued", "in_progress"])) -> "pending"
      true -> "unknown"
    end
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_timestamp(_value), do: nil
end
