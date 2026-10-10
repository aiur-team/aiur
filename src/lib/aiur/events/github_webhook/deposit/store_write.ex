defmodule Aiur.Events.GithubWebhook.Deposit.StoreWrite do
  @moduledoc """
  Writes one unit of `t:Aiur.Events.GithubWebhook.Deposit.work/0` into
  `Aiur.GitHub.ResourceStore` and the poll snapshots, and answers the keys
  written. The ordering guard, the thread-transition clock and the refusal
  report live here; `Aiur.Events.GithubWebhook.Deposit` describes the rules.
  """

  require Logger

  alias Aiur.GitHub.{PollSnapshots, ResourceStore}
  alias Aiur.StartTrigger.ProgressStore

  @spec merge_review_thread(String.t(), term(), map()) :: [ResourceStore.key()]
  def merge_review_thread(repo, pr_number, thread) do
    key = PollSnapshots.review_threads_key(repo, pr_number)

    case PollSnapshots.merge_review_thread(repo, pr_number, thread) do
      :ok -> confirm(key)
      :unchanged -> []
    end
  end

  @spec merge_check_run(String.t(), term(), String.t(), map()) :: [ResourceStore.key()]
  def merge_check_run(repo, target, head_sha, check_run) do
    key = PollSnapshots.ci_contexts_key(repo, target)

    case PollSnapshots.merge_check_run(repo, target, head_sha, check_run) do
      :ok -> confirm(key)
      :unchanged -> []
    end
  end

  @spec invalidate_review_threads(String.t(), term()) :: [ResourceStore.key()]
  def invalidate_review_threads(repo, pr_number) do
    PollSnapshots.invalidate_review_threads(repo, pr_number)
    []
  end

  @spec store(ResourceStore.resource_type(), String.t(), term(), term(), String.t() | nil) :: [ResourceStore.key()]
  def store(_type, _repo, _id, body, _version) when not (is_map(body) or is_list(body)), do: []

  # The `:issue_blocked_by` entry is the reader's answer to
  # `GET .../dependencies/blocked_by`, so it must hold the full blocker list —
  # a single webhook edge overwriting a held list would silently forget every
  # blocker the reader already knew. The edge is therefore merged, inside the
  # store's compare-and-swap, into the list the entry already holds — and only
  # into an *existing* list: an absent entry is not a hole to fill with one
  # edge, it is the store's statement that it has no complete answer, and
  # fabricating `[edge]` would have `fetch_blocked_by` serve a partial list as
  # the whole truth for up to the retention window (#2326, review). The write
  # carries the delivery's own marker and derives a content validator, so the
  # dispatch gate's later revalidating read sends `If-None-Match` and costs a
  # free `304` when nothing changed.
  def store(:issue_blocked_by, repo, id, blocker, version) when is_map(blocker) do
    case ResourceStore.key_for_repo(:issue_blocked_by, repo, id) do
      nil ->
        []

      key ->
        case ResourceStore.update_resource(
               key,
               &merge_blocked_by_edge(&1, blocker),
               source: :webhook,
               version: version,
               etag: :derive
             ) do
          :unchanged -> []
          :ok -> confirm(key)
        end
    end
  end

  def store(:issue_blocked_by, _repo, _id, _body, _version), do: []

  def store(type, repo, id, body, version) do
    case ResourceStore.key_for_repo(type, repo, id) do
      nil ->
        []

      key ->
        case deposit_unless_older(key, body, version) do
          :unchanged ->
            []

          :ok ->
            record_progress(type, id, body, repo)
            confirm(key)
        end
    end
  end

  defp record_progress(:branch_pull_request, id, body, repo), do: ProgressStore.delivery(id, body, repo)
  defp record_progress(_type, _id, _body, _repo), do: :ok

  @spec store_thread_transition(String.t(), term(), String.t(), map(), String.t() | nil, String.t() | nil) :: [ResourceStore.key()]
  def store_thread_transition(repo, id, action, thread, generation, version) do
    case ResourceStore.key_for_repo(:pr_review_thread, repo, id) do
      nil ->
        []

      key ->
        result =
          ResourceStore.update_resource(
            key,
            &accept_thread_transition(&1, &2, action, thread, generation, version),
            source: :webhook,
            etag: :derive
          )

        if result == :unchanged, do: [], else: confirm(key)
    end
  end

  # The one edge a delivery names is merged into whatever the entry already
  # holds, never replacing a fuller list the reader holds. A repeat delivery of
  # the same edge is declined inside the store's swap. An absent entry is left
  # alone (answered `:unchanged`) rather than being started from a single edge,
  # which would serve an incomplete list as the complete answer.
  defp merge_blocked_by_edge(held, blocker) when is_list(held) do
    if Enum.any?(held, &(Map.get(&1, "id") == Map.get(blocker, "id"))),
      do: :unchanged,
      else: held ++ [blocker]
  end

  defp merge_blocked_by_edge(_absent, _blocker), do: :unchanged

  # The ordering guard runs *inside* the store's compare-and-swap, against the
  # marker the entry holds at the instant of the write. Asking the store first and
  # depositing afterwards made this a check-then-act with a whole round trip in
  # the middle: a newer delivery or a mutation response landing in that gap was
  # answered "no regression" and then overwritten by this older body, `"state"`
  # included — the exact rollback the guard exists to refuse, committed by the
  # guard's own call site. Keep the comparison in `accept/4`; hoisting it back out
  # to a separate read restores the defect and nothing here would say so.
  #
  # `:derive`: a delivery carries no GitHub ETag, so the store derives a
  # content-based validator from the body it deposits. A body without a
  # validator is exactly the state in which a strict read pays full price —
  # `ResourceStore.etag/1` answers only beside a held body, and without one
  # every later conditional read is a 200 instead of a free `304`. The store
  # keeps a held validator when the body is unchanged, so a re-delivery of the
  # same body never knocks out a GitHub ETag a fetch already recorded (#2126).
  defp deposit_unless_older(key, body, version) do
    ResourceStore.update_resource(
      key,
      &accept(&1, &2, body, version),
      source: :webhook,
      version: version,
      etag: :derive
    )
  end

  # Answers the body to deposit, or `:unchanged` to decline the write — evaluated
  # by the store inside its swap, so `held` is the marker the entry carries at
  # that instant rather than one read a round trip earlier.
  defp accept(_held_body, %{version: held}, body, version) do
    if ResourceStore.regression?(held, version), do: :unchanged, else: body
  end

  # The transition carries its own ordering clock. The marker stores the
  # transition's `updated_at` under `"updated_at"`, so it never shares the
  # entry's version slots — which on this same key the comment pipe also writes
  # (`mark_processed` records the published comment's version) and which a
  # mutation's thread deposit records as the body version. The ordering guard
  # compares the incoming transition's `updated_at` against the held marker's,
  # not against whatever a different pipe last wrote to the entry: a review
  # comment edited after a resolve/unresolve transition can no longer occupy the
  # comparison slot and make the next genuine transition look like `:unchanged`.
  defp accept_thread_transition(held, _marker, action, thread, generation, version) do
    held_transition_at = transition_at(held)

    cond do
      ResourceStore.regression?(held_transition_at, version) ->
        :unchanged

      same_thread_transition?(held, action, held_transition_at, version) ->
        :unchanged

      true ->
        data =
          %{
            "webhook_action" => action,
            "generation" => generation,
            "thread" => thread
          }
          |> Map.put("updated_at", version)
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        case latest_unresolved_generation(held, action, generation) do
          value when is_binary(value) and value != "" -> Map.put(data, "latest_unresolved_generation", value)
          _other -> data
        end
    end
  end

  defp transition_at(%{"updated_at" => updated_at}) when is_binary(updated_at) and updated_at != "", do: updated_at
  defp transition_at(_held), do: nil

  defp latest_unresolved_generation(_held, "unresolved", generation), do: generation
  defp latest_unresolved_generation(%{"latest_unresolved_generation" => generation}, _action, _generation), do: generation
  defp latest_unresolved_generation(%{"webhook_action" => "unresolved", "generation" => generation}, _action, _generation), do: generation
  defp latest_unresolved_generation(_held, _action, _generation), do: nil

  defp same_thread_transition?(%{"webhook_action" => action}, action, held_transition_at, version),
    do: is_nil(version) or held_transition_at == version

  defp same_thread_transition?(_held, _action, _held_transition_at, _version), do: false

  # The store refuses a body it cannot encode or one past its size cap, and a
  # refusal is silent by design — `fetch/1` simply misses and the reader pays
  # for a read, exactly as it did before the store existed. Said out loud here
  # because a delivery is the one writer that cannot be retried: nothing will
  # send this body again.
  defp confirm(key) do
    case ResourceStore.fetch(key) do
      {:ok, _entry} ->
        [key]

      :miss ->
        Logger.warning("GithubWebhook.Deposit body refused by store key=#{inspect(key)}; readers will fetch it instead")

        []
    end
  end

  @spec drop(ResourceStore.resource_type(), String.t(), term()) :: [ResourceStore.key()]
  def drop(type, repo, id) do
    case ResourceStore.key_for_repo(type, repo, id) do
      nil ->
        []

      key ->
        ResourceStore.drop_data(key)
        []
    end
  end
end
