defmodule Aiur.LandingWatch.MergeGroupQuarantine.ModuleQuarantine do
  @moduledoc """
  Files one flake ticket and one quarantine PR per test module (or browser spec), not per test.

  One CI run that fails several tests of a module from a shared cause would otherwise open one PR
  per test, each rewriting the same list lines from the same base, and clog the merge queue (#7748).
  Journal claims, tickets and retries stay keyed per test identity.
  """

  alias Aiur.LandingWatch.{FlakeFilingGate, FlakeRecorder, Journal, MainRunEvidence, QuarantineEvidence, QuarantinePR, QuarantineRetry}

  require Logger

  @doc "Merges per-test candidates into one candidate per module; `identity` is the most recent failure."
  @spec group([map()]) :: [map()]
  def group(candidates) do
    candidates
    |> Enum.group_by(&QuarantinePR.module_key(&1.identity))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_key, members} ->
      rows = members |> Enum.flat_map(& &1.rows) |> Enum.sort_by(& &1["at_ms"], :desc)
      [latest | _] = rows
      identities = [latest["identity"] | members |> Enum.map(& &1.identity) |> Enum.sort() |> List.delete(latest["identity"])]
      %{identity: latest["identity"], identities: identities, rows: rows, observations: Enum.map(rows, &QuarantineEvidence.observation/1)}
    end)
  end

  @spec quarantine_with_retry(map(), map(), map(), [map()], String.t(), keyword()) :: :ok | {:error, term()}
  def quarantine_with_retry(candidate, tickets, done, rows, base, opts) do
    ticket = Enum.find_value(candidate.identities, &Map.get(tickets, &1))

    case quarantine(candidate, ticket, done, rows, base, opts) do
      :ok -> each(candidate.identities, &QuarantineRetry.succeeded(claim(&1), opts))
      {:error, _} = error -> Enum.each(candidate.identities, &QuarantineRetry.failed(claim(&1), error, opts)) && error
    end
  end

  @spec claim(String.t()) :: String.t()
  def claim(identity), do: "quarantine-pr :: " <> to_string(identity)

  defp quarantine(candidate, nil, done, rows, base, opts) do
    pending = Enum.reject(candidate.identities, &Map.has_key?(done, skip_claim(&1, candidate)))
    {listed, unlisted} = Enum.split_with(pending, &listed?(&1, opts))

    with :ok <- skip(listed, candidate, opts) do
      case unlisted do
        [] -> :ok
        _ -> file_if_eligible(narrow(candidate, unlisted), rows, base, opts)
      end
    end
  end

  defp quarantine(candidate, ticket, _done, _rows, _base, opts), do: open_quarantine(candidate, ticket, opts)

  # An unreadable list falls back to filing; QuarantinePR.open re-checks it before publishing.
  defp listed?(identity, opts) do
    case QuarantinePR.already_quarantined?(identity, opts) do
      {:ok, listed?} ->
        listed?

      unknown ->
        Logger.warning("quarantine list unreadable; filing without dedupe identity=#{identity} reason=#{inspect(unknown)}")
        false
    end
  end

  # The filed ticket names the most recent failure among the tests still to quarantine.
  defp narrow(candidate, identities) do
    rows = Enum.filter(candidate.rows, &(&1["identity"] in identities))
    latest = hd(rows)["identity"]
    %{candidate | identity: latest, identities: [latest | List.delete(identities, latest)], rows: rows, observations: Enum.map(rows, &QuarantineEvidence.observation/1)}
  end

  defp file_if_eligible(candidate, rows, base, opts) do
    [latest | _] = candidate.rows

    case FlakeFilingGate.decide(failure(latest, []), run(latest), latest["at_ms"], rows, base, opts) do
      :file -> file_ticket_then_quarantine(candidate, latest, opts)
      {:skip, _reason} -> skip(candidate.identities, candidate, opts)
    end
  end

  defp file_ticket_then_quarantine(candidate, latest, opts) do
    remember = fn
      :already_quarantined -> skip(candidate.identities, candidate, opts)
      ticket -> each(candidate.identities, &Journal.put_flake_ticket(&1, ticket, opts))
    end

    recorder = Keyword.get(opts, :flake_recorder, &FlakeRecorder.record/4)
    others = candidate.identities |> List.delete(latest["identity"]) |> Enum.map(&(&1 |> String.split(" :: ", parts: 2) |> List.last()))

    with :ok <- recorder.(failure(latest, others), run(latest), [], Keyword.put(opts, :issue_recorded_fun, remember)),
         {:ok, state} <- Journal.state(opts) do
      case {get_in(state, ["flake_tickets", latest["identity"]]), Map.has_key?(Map.get(state, "flakes", %{}), skip_claim(latest["identity"], candidate))} do
        {ticket, _} when is_integer(ticket) -> open_quarantine(candidate, ticket, opts)
        {_, true} -> :ok
        _ -> {:error, :flake_ticket_unconfirmed}
      end
    end
  end

  defp open_quarantine(candidate, ticket, opts) do
    with {:ok, claimed} <- claim_new(candidate.identities, opts) do
      case claimed do
        [] -> :ok
        _ -> publish(%{candidate | identities: claimed, identity: hd(claimed)}, ticket, opts)
      end
    end
  end

  defp publish(candidate, ticket, opts) do
    case Keyword.get(opts, :quarantine_pr_fun, &QuarantinePR.open/3).(candidate, ticket, opts) do
      {:ok, _} -> each(candidate.identities, &(Journal.claim_flake("quarantine-requeue :: " <> &1, opts) |> claim_result()))
      {:error, _} = error -> release(candidate.identities, error, opts)
    end
  end

  defp claim_new(identities, opts) do
    Enum.reduce_while(identities, {:ok, []}, fn identity, {:ok, claimed} ->
      case Journal.claim_flake(claim(identity), opts) do
        {:ok, :new} -> {:cont, {:ok, claimed ++ [identity]}}
        {:ok, :already_claimed} -> {:cont, {:ok, claimed}}
        {:error, _} = error -> {:halt, release(claimed, error, opts)}
      end
    end)
  end

  defp release(identities, error, opts) do
    case each(identities, &Journal.release_flake(claim(&1), opts)) do
      :ok -> error
      {:error, reason} -> {:error, {:quarantine_claim_release_failed, reason}}
    end
  end

  defp skip(identities, candidate, opts), do: each(identities, &(Journal.claim_flake(skip_claim(&1, candidate), opts) |> claim_result()))

  # Keyed by each test's own latest run, as before grouping.
  defp skip_claim(identity, candidate), do: "quarantine-skip :: #{identity} :: #{Enum.find(candidate.rows, &(&1["identity"] == identity))["run_url"]}"

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp failure(row, others) do
    [module, name] = String.split(row["identity"], " :: ", parts: 2)
    failure = %{module: module, name: name, job: row["job"] || "unknown job", excerpt: row["excerpt"] || "", path: row["path"]}
    if others == [], do: failure, else: Map.put(failure, :module_tests, others)
  end

  defp run(row), do: %{"id" => MainRunEvidence.run_id(row["run_url"]), "html_url" => row["run_url"], "head_sha" => row["head_sha"]}

  defp claim_result({:ok, _}), do: :ok
  defp claim_result(error), do: error
end
