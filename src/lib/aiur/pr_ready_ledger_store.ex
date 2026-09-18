defmodule Aiur.PrReadyLedgerStore do
  @moduledoc """
  Durable record of what the polls know about each ticket PR's draft state.

  `Aiur.Orchestrator.ReadyForReviewTransitions` keeps one entry per
  `{ticket, pr_number}`:

    * `:draft` — a poll saw the PR as a draft; the next ready observation
      publishes `ready_for_review`.
    * `{:announced, head_sha}` — `ready_for_review` was published for the PR.
    * `:never_draft` — the PR was opened ready; GitHub's webhook does not send
      `ready_for_review` for that, so neither does the poll.

  The record must survive a daemon restart (#2707): a PR that goes ready while
  the daemon restarts is first seen ready by the new daemon, and an announced PR
  must not be announced again. The file therefore lives beside the other
  daemon-private state, not in the per-launch log directory.

  Persistence is best-effort. A read or write failure logs and falls back to
  memory, so a disk problem costs at most a missed or repeated wake after a
  restart, never a crashed poll.
  """

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @type key :: {String.t(), pos_integer()}
  @type entry :: :draft | :never_draft | {:announced, String.t()}
  @type ledger :: %{optional(key()) => entry()}

  @file_name "pr-ready-ledger.json"

  @spec load() :: ledger()
  def load do
    with {:ok, path} <- path_for(),
         {:ok, persisted} <- JsonStore.read(path, %{"entries" => []}) do
      decode(persisted)
    else
      {:error, reason} ->
        Logger.warning("PR ready ledger could not be read: #{inspect(reason)}; starting empty")
        %{}
    end
  end

  @spec save(ledger()) :: :ok
  def save(ledger) when is_map(ledger) do
    case path_for() do
      {:ok, path} ->
        JsonStore.write!(path, %{"entries" => encode(ledger)})

      {:error, reason} ->
        Logger.warning("PR ready ledger has no state directory: #{inspect(reason)}; keeping it in memory")
    end

    :ok
  rescue
    error ->
      Logger.warning("PR ready ledger persistence failed: #{Exception.message(error)}")
      :ok
  end

  @doc false
  @spec path_for() :: {:ok, Path.t()} | {:error, term()}
  def path_for do
    case Application.get_env(:aiur, :pr_ready_ledger_path) do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        with {:ok, dir} <- Paths.decision_state_dir() do
          {:ok, Path.join(dir, @file_name)}
        end
    end
  end

  defp encode(ledger) do
    ledger
    |> Enum.sort()
    |> Enum.map(fn {{ticket, pr_number}, entry} ->
      Map.merge(%{"ticket" => ticket, "pr" => pr_number}, encode_entry(entry))
    end)
  end

  defp encode_entry(:draft), do: %{"state" => "draft"}
  defp encode_entry(:never_draft), do: %{"state" => "never_draft"}
  defp encode_entry({:announced, head_sha}), do: %{"state" => "announced", "head" => head_sha}

  defp decode(%{"entries" => entries}) when is_list(entries) do
    Enum.reduce(entries, %{}, fn persisted, acc ->
      case decode_entry(persisted) do
        {key, entry} -> Map.put(acc, key, entry)
        nil -> acc
      end
    end)
  end

  defp decode(_persisted), do: %{}

  defp decode_entry(%{"ticket" => ticket, "pr" => pr_number} = persisted)
       when is_binary(ticket) and ticket != "" and is_integer(pr_number) and pr_number > 0 do
    case persisted do
      %{"state" => "draft"} -> {{ticket, pr_number}, :draft}
      %{"state" => "never_draft"} -> {{ticket, pr_number}, :never_draft}
      %{"state" => "announced", "head" => head} when is_binary(head) -> {{ticket, pr_number}, {:announced, head}}
      _other -> nil
    end
  end

  defp decode_entry(_persisted), do: nil
end
