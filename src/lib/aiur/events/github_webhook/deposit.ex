defmodule Aiur.Events.GithubWebhook.Deposit do
  @moduledoc """
  Writes the bodies a verified webhook delivery already carries into
  `Aiur.GitHub.ResourceStore`.

  ## Why the delivery is the right writer

  A delivery is the only writer that costs nothing. GitHub has already paid for
  the round trip, the payload is already HMAC-verified, and it arrives *first* —
  before any sweep would have read the same object. Every other writer in the
  cache spends either an API call or a mutation. So a delivery that fires an
  event and then throws its payload away has paid for a body twice: once when
  GitHub sent it, and again when some reader later fetches the same object
  because the store holds nothing for it.

  This module therefore runs on the receiving side of every delivery for a
  tracked repository, *before* the publish, so a consumer woken by the event
  finds the body already there.

  ## Shapes

  Individual comment and review events are deposited in the **poller's** shape,
  through `Aiur.Events.GithubWebhook.Normalizer.comment_shape/1` and
  `review_shape/1` — the same projection the normalizer publishes. That is not
  cosmetic: the store is read by consumers that must not be able to tell a
  delivered comment from a polled one, and a REST delivery carries roughly twice
  the keys the poller's GraphQL batch produces.

  Whole resources — an issue, a pull request, a check run — are deposited as
  GitHub's own object, because that is what both a conditional re-read and a
  mutation response return for them, and a consumer that later reconciles one
  against upstream must be comparing like with like.

  ## What this module deliberately does not do

  **It never marks anything processed** (KTD5). `put_resource/3` is called
  without `:processed`, so a deposit moves `:data_version` (the version of the
  body held) and never `:version` (the version some pipe handled). Two
  consequences, both load-bearer:

    * A delivery cannot drag a suppression mark onto a version nothing handled —
      the hazard that would silently discard an *older* sibling comment whose own
      delivery was lost.
    * `Aiur.Events.Publisher` remains the sole author of the processed mark, and
      it records it only *after* a successful publish. Depositing a body
      therefore cannot suppress an event, including for a change Aiur itself
      made: the bot self-loop filter still runs, and the body is cached while the
      event stays filtered.

  **It is a cache, never the system of record** (KTD4). Webhook loss is measured:
  9 of 100 deliveries returned 502 during a daemon restart, GitHub retried none,
  and none arrived later. A deposited entry is ordinary store content — the
  safety sweep still reads, still reconciles, and the absence of a delivery is
  never read as the absence of change.

  A `deleted` action drops the held body rather than depositing one, because
  serving a body for an object that no longer exists is worse than a miss.

  ## Ordering

  GitHub does not order deliveries, and a delivery carries more than the object
  it is about — an `issue_comment` also carries the whole issue and its label
  set. Deposits are therefore last-writer-wins with one guard: a body whose
  version is strictly older than the version already held is refused, so a
  delayed delivery cannot walk a resource backwards and then stamp it as freshly
  fetched. Equal or unknown versions still write, because a body can legitimately
  change under an unchanged marker and the later arrival is the better answer.

  One field is knowingly shared: the entry's `:source` is written both by a
  deposit ("who supplied the body I hold") and by `mark_processed/3` ("who
  handled it"), so on a resource the two pipes both touched it reports the last
  writer of either kind. Suppression does not read it; it is provenance only.
  """

  require Logger

  alias Aiur.Events.GithubWebhook.Normalizer
  alias Aiur.GitHub.ResourceStore

  @typedoc """
  One unit of work this module produces from a delivery: either a body to
  deposit under an identity, or an identity whose held body must go.
  """
  @type work ::
          {ResourceStore.resource_type(), term(), term(), String.t() | nil}
          | {:drop, ResourceStore.resource_type(), term()}

  @doc """
  Deposits every body `payload` carries, and returns the keys written.

  `event_type` is the `X-GitHub-Event` header value, `repo` the tracked
  `"owner/name"` the caller already resolved. Never raises: the caller is an
  HTTP endpoint, and a cache write is never worth failing a delivery over.
  """
  @spec deposit(term(), term(), term()) :: [ResourceStore.key()]
  def deposit(event_type, payload, repo) when is_binary(event_type) and is_map(payload) and is_binary(repo) do
    if store_running?() do
      Enum.flat_map(bodies(event_type, payload), fn
        {:drop, type, id} -> drop(type, repo, id)
        {type, id, body, version} -> store(type, repo, id, body, version)
      end)
    else
      []
    end
  rescue
    error ->
      Logger.warning("GithubWebhook.Deposit skipped type=#{inspect(event_type)} error=#{Exception.message(error)}")
      []
  catch
    kind, reason ->
      # The caller absorbs a throw or exit as `%{status: :error}` for the whole
      # delivery. A cache write is never worth that, so it is caught here too.
      Logger.warning("GithubWebhook.Deposit skipped type=#{inspect(event_type)} reason=#{inspect({kind, reason})}")

      []
  end

  def deposit(_event_type, _payload, _repo), do: []

  # ---------------------------------------------------------------------------
  # What each delivery type carries
  # ---------------------------------------------------------------------------

  # An `issue_comment` delivery carries the comment *and* the whole issue it
  # hangs off, so one free delivery populates both.
  defp bodies("issue_comment", payload) do
    comment = Map.get(payload, "comment")
    issue = Map.get(payload, "issue")
    action = Map.get(payload, "action")

    # The issue rides along on its own terms. The action belongs to the
    # *comment*, so it must not reach the issue: deleting a comment would
    # otherwise discard the cached issue body, using a delivery that is carrying
    # a complete and current one.
    comment_deposits(:issue_comment, action, comment) ++ carried_issue_deposits(issue)
  end

  defp bodies("pull_request_review_comment", payload) do
    comment = Map.get(payload, "comment")
    action = Map.get(payload, "action")

    comment_deposits(:pr_review_comment, action, comment) ++
      pull_request_deposits(Map.get(payload, "pull_request"))
  end

  defp bodies("pull_request_review", payload) do
    review = Map.get(payload, "review")
    action = Map.get(payload, "action")

    review_deposits(action, review) ++ pull_request_deposits(Map.get(payload, "pull_request"))
  end

  defp bodies("pull_request", payload), do: pull_request_deposits(Map.get(payload, "pull_request"))

  defp bodies("issues", payload), do: issue_deposits(Map.get(payload, "action"), Map.get(payload, "issue"))

  # A check run is deposited under its own id, which is the only identity a
  # single delivery can honestly claim: it says nothing about the other runs on
  # the same head, so a consumer aggregating a head's checks must still read.
  defp bodies("check_run", payload) do
    run = Map.get(payload, "check_run")

    if is_map(run) do
      [{:check_run, Map.get(run, "id"), run, check_run_version(run)}]
    else
      []
    end
  end

  defp bodies(_event_type, _payload), do: []

  defp comment_deposits(_type, _action, comment) when not is_map(comment), do: []

  defp comment_deposits(type, "deleted", comment), do: [{:drop, type, Map.get(comment, "id")}]

  defp comment_deposits(type, action, comment) when action in ["created", "edited"] do
    [{type, Map.get(comment, "id"), Normalizer.comment_shape(comment), version(comment)}]
  end

  # Any other action (a reaction, an unknown future one) is not a statement
  # about the comment body, so it deposits nothing rather than re-writing what
  # is already held.
  defp comment_deposits(_type, _action, _comment), do: []

  defp review_deposits("submitted", review) when is_map(review) do
    [{:pr_review, Map.get(review, "id"), Normalizer.review_shape(review), version(review)}]
  end

  # An edit or a dismissal changes the review — its body, or its `state` to
  # `DISMISSED` — while `submitted_at` stays exactly where it was, and a REST
  # review carries no `updated_at`. Deposited as "version unknown" rather than
  # under the submission marker, because a changed body filed under an unchanged
  # version tells the next reader something false.
  defp review_deposits(action, review) when is_map(review) and action in ["edited", "dismissed"] do
    [{:pr_review, Map.get(review, "id"), Normalizer.review_shape(review), nil}]
  end

  defp review_deposits(_action, _review), do: []

  defp issue_deposits(_action, issue) when not is_map(issue), do: []

  # A deleted issue takes its label set with it. Leaving the labels behind would
  # hold a set for a body nothing holds — an entry that contradicts itself.
  defp issue_deposits("deleted", issue) do
    number = Map.get(issue, "number")
    [{:drop, :issue, number}, {:drop, :issue_labels, number}]
  end

  defp issue_deposits(_action, issue), do: carried_issue_deposits(issue)

  defp carried_issue_deposits(issue) when not is_map(issue), do: []

  defp carried_issue_deposits(issue) do
    number = Map.get(issue, "number")
    issue_version = version(issue)

    # GitHub's own `labels` array, which is what both a label mutation response
    # and a conditional re-read of the issue return. The label set rides on the
    # issue's version because it is part of the issue's own state.
    label_deposits =
      case Map.get(issue, "labels") do
        labels when is_list(labels) -> [{:issue_labels, number, labels, issue_version}]
        _other -> []
      end

    [{:issue, number, issue, issue_version}] ++ label_deposits
  end

  defp pull_request_deposits(pr) when is_map(pr), do: [{:pull_request, Map.get(pr, "number"), pr, version(pr)}]
  defp pull_request_deposits(_pr), do: []

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  defp store(_type, _repo, _id, body, _version) when not (is_map(body) or is_list(body)), do: []

  defp store(type, repo, id, body, version) do
    case ResourceStore.key_for_repo(type, repo, id) do
      nil ->
        []

      key ->
        case deposit_unless_older(key, body, version) do
          :unchanged -> []
          :ok -> confirm(key)
        end
    end
  end

  # The ordering guard runs *inside* the store's compare-and-swap, against the
  # marker the entry holds at the instant of the write. Asking the store first and
  # depositing afterwards made this a check-then-act with a whole round trip in
  # the middle: a newer delivery or a mutation response landing in that gap was
  # answered "no regression" and then overwritten by this older body, `"state"`
  # included — the exact rollback the guard exists to refuse, committed by the
  # guard's own call site. Keep the comparison in `accept/4`; hoisting it back out
  # to a separate read restores the defect and nothing here would say so.
  #
  # No `:etag`: a delivery carries no validator, and the store refuses a new
  # validator that arrives without the body it validates anyway.
  defp deposit_unless_older(key, body, version) do
    ResourceStore.update_resource(
      key,
      &accept(&1, &2, body, version),
      source: :webhook,
      version: version
    )
  end

  # Answers the body to deposit, or `:unchanged` to decline the write — evaluated
  # by the store inside its swap, so `held` is the marker the entry carries at
  # that instant rather than one read a round trip earlier.
  defp accept(_held_body, %{version: held}, body, version) do
    if regression?(held, version), do: :unchanged, else: body
  end

  # GitHub does not order deliveries, and a single delivery carries more than the
  # object it is about: an `issue_comment` also carries the whole issue and its
  # label set. So a delayed comment delivery can arrive holding a *pre-change*
  # snapshot of an issue a later delivery already deposited correctly.
  #
  # `put_resource/3` is an unconditional overwrite that stamps `fetched_at_ms`
  # with now, so accepting that write would not merely hold an older body — it
  # would describe it as freshly fetched, and a consumer asking for a body no
  # older than some window would be handed a body from before the change.
  #
  # Both markers are GitHub's own ISO-8601 timestamps, which sort lexically, so
  # a strictly older version is refused. Equal versions still write: the body may
  # legitimately differ under an unchanged marker (a dismissed review), and the
  # newer arrival is the better answer. A missing marker on either side is not a
  # judgement that anything went backwards, so it writes.
  #
  # A pure comparison of two markers, deliberately, so it can be evaluated inside
  # the store's swap instead of in a separate read.
  defp regression?(held, version) when is_binary(held) and is_binary(version), do: version < held
  defp regression?(_held, _version), do: false

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

  defp drop(type, repo, id) do
    case ResourceStore.key_for_repo(type, repo, id) do
      nil ->
        []

      key ->
        ResourceStore.drop_data(key)
        []
    end
  end

  # The resource's own mutation marker. `updated_at` for issues, pull requests
  # and comments; `submitted_at` for a review, which has no `updated_at` and
  # whose submission time is the marker the poller's cutoff already keys on.
  defp version(%{"updated_at" => updated_at}) when is_binary(updated_at) and updated_at != "", do: updated_at

  defp version(%{"submitted_at" => submitted_at}) when is_binary(submitted_at) and submitted_at != "",
    do: submitted_at

  defp version(_resource), do: nil

  # A check run has no `updated_at`. `completed_at` moves when the run finishes,
  # which is the only transition that changes what the run *says*. A run that has
  # not finished is deposited as "version unknown" rather than under
  # `started_at`, which does not move across `queued` → `in_progress`.
  defp check_run_version(run) do
    case Map.get(run, "completed_at") do
      completed when is_binary(completed) and completed != "" -> completed
      _other -> nil
    end
  end

  # A store that is not running accepts every write into nothing and would then
  # be reported as a refusal by `confirm/1` for every body in the delivery.
  # Answered once per delivery instead — through the store's own view, which is
  # the table the writes land in.
  defp store_running?, do: ResourceStore.running?()
end
