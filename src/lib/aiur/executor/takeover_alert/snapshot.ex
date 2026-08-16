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

  @type result :: %{tickets: [map()], authoritative?: boolean()}

  @spec fetch(DateTime.t()) :: result()
  def fetch(now), do: fetch(now, [])

  @doc false
  @spec fetch(DateTime.t(), keyword()) :: result()
  def fetch(_now, opts) do
    running = running_identifiers(Keyword.get(opts, :running_fun, &default_running_identifiers/0))
    {members, authoritative?} = membership_tickets(Keyword.get(opts, :membership_fun, &CurrentRunMembership.snapshot/0))

    tickets =
      running
      |> Map.keys()
      |> Enum.reduce(members, fn identifier, acc ->
        Map.put_new(acc, identifier, %{identifier: identifier, terminal?: false, in_scope?: true})
      end)
      |> Map.values()
      |> Enum.map(&Map.put(&1, :live_owner?, Map.has_key?(running, &1.identifier)))

    %{tickets: tickets, authoritative?: authoritative?}
  end

  defp membership_tickets(membership_fun) do
    case membership_fun.() do
      %{members: members, health: health, truncated?: truncated?} when is_list(members) ->
        tickets =
          Enum.reduce(members, %{}, fn member, acc ->
            case get_in(member, [:identity, :identifier]) do
              nil ->
                acc

              identifier ->
                identity = Map.get(member, :identity, %{})

                Map.put(acc, identifier, %{
                  identifier: identifier,
                  terminal?: Map.get(member, :terminal?, false),
                  in_scope?: true,
                  url: identity_url(identity)
                })
            end
          end)

        {tickets, health == :healthy and not truncated?}

      _ ->
        {%{}, false}
    end
  rescue
    _ -> {%{}, false}
  catch
    _, _ -> {%{}, false}
  end

  defp running_identifiers(running_fun) do
    running_fun.()
    |> Map.new(&{&1, true})
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp default_running_identifiers do
    Orchestrator.list_running_active_identifiers(Orchestrator, 1_000)
  end

  @doc """
  Best-effort open-PR evidence for a ticket, or `nil` when no open PR exists or
  the tracker is unavailable. `opts` forwards to the GitHub client so tests can
  inject a `request_fun`.
  """
  @spec fetch_open_pr(map(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_open_pr(ticket, opts \\ [])

  def fetch_open_pr(%{identifier: identifier} = ticket, opts) do
    with {:ok, listed} when is_map(listed) <- GitHubClient.fetch_open_pull_request_for_branch(identifier, opts),
         number when not is_nil(number) <- Map.get(listed, "number"),
         {:ok, detail} when is_map(detail) <- GitHubClient.fetch_open_pull_request(number, opts),
         {:ok, pushed_at} <- head_commit_timestamp(detail, opts) do
      {:ok,
       %{
         number: number,
         created_at: parse_timestamp(Map.get(detail, "created_at")),
         pushed_at: pushed_at,
         mergeable_state: Map.get(detail, "mergeable_state"),
         ci_state: maybe_ci_state(detail, ticket, opts)
       }}
    else
      {:ok, nil} -> {:ok, nil}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_pull_request_evidence}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def fetch_open_pr(_ticket, _opts), do: {:ok, nil}

  defp head_commit_timestamp(pr, opts) do
    case get_in(pr, ["head", "sha"]) do
      sha when is_binary(sha) and sha != "" -> GitHubClient.fetch_commit_timestamp(sha, opts)
      _ -> {:ok, nil}
    end
  end

  defp maybe_ci_state(pr, %{enrich_ci?: true}, opts) do
    head_sha = get_in(pr, ["head", "sha"])

    if is_binary(head_sha) and head_sha != "" do
      ci_state_for_sha(head_sha, opts)
    end
  end

  defp maybe_ci_state(_pr, _ticket, _opts), do: nil

  defp ci_state_for_sha(sha, opts) do
    case PullRequests.fetch_commit_ci_status(sha, opts) do
      {:ok, %{check_runs: check_runs, commit_status: commit_status}}
      when is_list(check_runs) and is_map(commit_status) ->
        summarize_ci(check_runs, commit_status)

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp summarize_ci(check_runs, commit_status) do
    statuses = Enum.map(check_runs, &Map.get(&1, "status"))
    conclusions = Enum.map(check_runs, &Map.get(&1, "conclusion"))
    legacy_states = commit_status |> Map.get("statuses", []) |> Enum.map(&Map.get(&1, "state"))
    combined = Map.get(commit_status, "state")
    failures = ["failure", "error", "timed_out", "action_required"]
    combined_states = if legacy_states == [], do: [combined], else: []
    failing = Enum.count(conclusions ++ legacy_states ++ combined_states, &(&1 in failures))

    cond do
      failing > 0 ->
        "failing (#{failing} check#{if(failing == 1, do: "", else: "s")})"

      Enum.any?(statuses, &(&1 in ["queued", "in_progress"])) or
        Enum.any?(legacy_states, &(&1 == "pending")) or combined == "pending" ->
        "pending"

      conclusions != [] or legacy_states != [] or combined == "success" ->
        "success"

      true ->
        "unknown"
    end
  end

  defp identity_url(%{kind: :github, owner: owner, repository: repository, identifier: identifier})
       when is_binary(owner) and is_binary(repository) and is_binary(identifier) do
    "https://github.com/#{owner}/#{repository}/issues/#{identifier}"
  end

  defp identity_url(_identity), do: nil

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_timestamp(_value), do: nil
end
