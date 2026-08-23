defmodule Aiur.Events.GithubWebhook do
  @moduledoc """
  Publish tail for verified GitHub webhook deliveries.

  `Aiur.Events.GithubWebhook.Normalizer` decides *what* a delivery means;
  this module performs the same publish the pollers perform —
  `Aiur.Events.Sanitizer.github_payload/2` followed by
  `Aiur.Events.Publisher.publish/3` — so push and poll are indistinguishable
  to every consumer, and `Publisher`'s replay dedup collapses the pair when
  both observe the same GitHub event.

  Deliveries whose event is owned by a stateful reconciler (label transitions,
  CI outcomes, `synchronize`) do not publish here. They wake the orchestrator
  to run its poll cycle now, so the *existing* producer emits the *existing*
  event without a poll-interval wait. So do PR state changes (`pr.opened` /
  `pr.merged`) and a newly-opened ticket that already carries an active state
  label — the deliveries that imply new dispatcher work but have no direct bus
  consumer of their own. Consecutive wakes are coalesced, so a delivery burst
  produces one cycle, not one per delivery (#2365).

  The wake is `Aiur.Orchestrator.request_refresh/0` — the SPEC §8.1 coalesced
  immediate tick — not a fetch of its own. It only schedules the cycle that
  acts on the state the delivery already deposited (#2319), so it issues no
  GitHub request and never re-fetches what the delivery told us. Deliveries
  that imply no dispatcher work (comments, reviews, unactionable new issues,
  drops) never wake, so a busy repo's continuous irrelevant traffic cannot pin
  the dispatcher at its base interval and delete the idle backoff this wake
  exists to interrupt.

  Every delivery that resolves to a tracked repository is also recorded with
  `Aiur.Webhooks.record_delivery/2` — the seam W-6 (#1683) exposes for exactly
  this caller. Configuration only says a webhook is *expected*; an observed
  delivery is what proves it works, so without this call a repo stays "configured
  but unproven" forever and W-6's degradation sweep has nothing to hold onto.

  Every such delivery also deposits the bodies it carries into
  `Aiur.GitHub.ResourceStore` through `Aiur.Events.GithubWebhook.Deposit`. A
  delivery is the cheapest writer the cache has — GitHub already paid for the
  round trip — so firing the event and discarding the payload means paying for
  the same body twice. The deposit never marks anything processed; that stays
  `Publisher`'s, after a successful publish.
  Recording happens *before* the publish, so a consumer reacting synchronously
  can never observe the repo as silent while it handles one of that repo's
  deliveries. Deliveries for untracked repositories record nothing: the fleet
  does not track them, so their liveness is not ours to assert.

  Nothing in this module is allowed to take down the caller. The receiver is an
  HTTP endpoint holding an unvalidated payload from the public internet: an
  unrecognized event type is logged and ignored, a malformed payload is
  rejected, and an unexpected exception is caught and reported as an error
  rather than raised.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.Events.GithubWebhook.{Deposit, Normalizer, ThreadResolver}
  alias Aiur.Events.{Publisher, Sanitizer}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Issues
  alias Aiur.GitHub.StatePolicy
  alias Aiur.Orchestrator
  alias Aiur.Webhooks

  @reconcile_debounce_ms 2_000

  @type outcome :: %{
          required(:status) => :published | :reconciled | :dropped | :error,
          optional(:published) => [String.t()],
          optional(:results) => [term()],
          optional(:reason) => term(),
          optional(:hint) => map()
        }

  @doc """
  Handles one verified delivery.

  `event_type` is the `X-GitHub-Event` header value; `payload` is the decoded
  JSON body. Always returns an outcome map; never raises.

  Options are passed through to `Normalizer.normalize/3` (notably `:repo`),
  plus:

    * `:publish_fun` — 3-arity override for `Publisher.publish/3` (test seam)
    * `:reconcile_fun` — 1-arity override for the reconcile nudge
    * `:request_refresh_fun` — 0-arity override for the dispatcher wake
      (test seam; defaults to `Aiur.Orchestrator.request_refresh/0`)
    * `:actionable_label_fun` — 1-arity `(label_name -> boolean)` deciding
      whether a newly-opened issue's label implies dispatch work (test seam;
      defaults to the configured active-state set)
    * `:request_fun` — transport seam for `Aiur.Events.GithubWebhook.ThreadResolver`,
      which resolves the review thread a `pull_request_review_comment` delivery
      belongs to (test seam; defaults to the live GitHub transport)
    * `:at` / `:server` — passed through to `Aiur.Webhooks.record_delivery/2`
  """
  @spec handle_delivery(term(), term(), keyword()) :: outcome()
  def handle_delivery(event_type, payload, opts \\ []) do
    payload = maybe_resolve_review_thread(event_type, payload, opts)
    record_tracked_delivery(event_type, payload, opts)

    case Normalizer.normalize(event_type, payload, opts) do
      {:publish, triples} ->
        outcome = publish_all(triples, opts)
        maybe_wake_on_publish(triples, opts)
        outcome

      {:reconcile, hint} ->
        if actionable_reconcile?(hint, payload, opts) do
          request_reconcile(hint, opts)
          %{status: :reconciled, hint: hint}
        else
          %{status: :dropped, reason: {:uninteresting_action, "issues", "opened"}}
        end

      {:drop, {:unsupported_event, type} = reason} ->
        Logger.debug("GithubWebhook ignoring unsupported delivery type=#{inspect(type)}")
        %{status: :dropped, reason: reason}

      {:drop, reason} ->
        Logger.debug("GithubWebhook dropped delivery type=#{inspect(event_type)} reason=#{inspect(reason)}")
        %{status: :dropped, reason: reason}

      {:error, reason} ->
        Logger.warning("GithubWebhook rejected delivery type=#{inspect(event_type)} reason=#{inspect(reason)}")
        %{status: :error, reason: reason}
    end
  rescue
    error ->
      Logger.error("GithubWebhook delivery raised type=#{inspect(event_type)} error=#{Exception.message(error)}")
      %{status: :error, reason: {:exception, Exception.message(error)}}
  catch
    kind, reason ->
      Logger.error("GithubWebhook delivery exited type=#{inspect(event_type)} reason=#{inspect({kind, reason})}")
      %{status: :error, reason: {kind, reason}}
  end

  # Liveness is a property of the delivery, not of what the delivery turned out
  # to mean: an event type this fleet ignores still proves the webhook, the App
  # install, and the tunnel are all working. So this keys off the tracked-repo
  # filter alone and runs ahead of `normalize/3`, not off the publish outcome.
  #
  # The same tracked-repo answer also gates the resource deposit, for the same
  # reason and from the same judgement: the bodies a delivery carries are worth
  # caching exactly when the fleet tracks the repository they belong to.
  # Depositing happens *before* the publish so a consumer woken by the event
  # finds the body already held rather than racing the writer that is handing it
  # the wake.
  defp record_tracked_delivery(event_type, payload, opts) do
    case Normalizer.tracked_repo(payload, opts) do
      {:ok, repo} ->
        Webhooks.record_delivery(repo, Keyword.take(opts, [:at, :server]))
        Deposit.deposit(event_type, payload, repo)
        :ok

      _untracked_or_malformed ->
        :ok
    end
  end

  # A `pull_request_review_comment` delivery carries the comment's own GraphQL
  # node id but not its thread's. The poller keys thread comments on the thread
  # node id, so the webhook must resolve it too or the two pipes key the same
  # event differently and wake the agent twice for one comment (#2081). The
  # resolved id is stamped onto the delivery's comment, where the normalizer
  # reads it and keys on the thread.
  #
  # Gated on the tracked-repo filter first: a resolution costs a GraphQL point,
  # and a delivery for a repository the fleet does not track is going to be
  # dropped anyway, so paying for the lookup would buy nothing.
  #
  # Best-effort: a delivery with no `node_id`, or a lookup that fails, is left
  # untouched and the normalizer falls back to per-comment keying — today's
  # behaviour. A duplicate wake is recoverable; a dropped delivery is not.
  defp maybe_resolve_review_thread("pull_request_review_comment", payload, opts) when is_map(payload) do
    case Normalizer.tracked_repo(payload, opts) do
      {:ok, _repo} -> resolve_review_thread(payload, opts)
      _untracked_or_malformed -> payload
    end
  end

  defp maybe_resolve_review_thread(_event_type, payload, _opts), do: payload

  # Best-effort resolution of the comment's thread id: a delivery with no
  # `node_id`, or a lookup that fails, falls through to the per-comment key the
  # normalizer already uses — a duplicate wake is recoverable, a dropped
  # delivery is not.
  defp resolve_review_thread(payload, opts) do
    with node_id when is_binary(node_id) and node_id != "" <- get_in(payload, ["comment", "node_id"]),
         {:ok, thread_id} <- ThreadResolver.resolve(node_id, opts) do
      put_in(payload, ["comment", "review_thread_id"], thread_id)
    else
      _other -> payload
    end
  end

  defp publish_all(triples, opts) do
    publish_fun = Keyword.get(opts, :publish_fun, &Publisher.publish/3)

    results =
      Enum.map(triples, fn {topic, payload, publish_opts} ->
        sanitized = Sanitizer.github_payload(payload, Keyword.get(publish_opts, :actor))
        {topic, publish_fun.(topic, sanitized, publish_opts)}
      end)

    published = for {topic, {:ok, _id, _subscribers}} <- results, do: topic

    %{status: :published, published: published, results: results}
  end

  # The reconcilers that own label and CI events live in the orchestrator's
  # poll cycle, so the delivery wakes the orchestrator to run its cycle now
  # rather than waiting out the remaining poll interval. A delivery burst
  # (a merge fires several events in one second) must not produce its own
  # cycle per delivery, so wakes are coalesced into one per debounce window.
  defp request_reconcile(hint, opts) do
    case Keyword.get(opts, :reconcile_fun) do
      fun when is_function(fun, 1) -> fun.(hint)
      _other -> maybe_wake_orchestrator(opts)
    end
  end

  # A `:publish` delivery has already handed its event to the bus. Most of
  # those (comments, reviews) are their own wake — the orchestrator subscribes
  # to the topic and reacts without a poll — so they must not also trigger a
  # dispatcher cycle. The exceptions are PR state changes (`pr.opened` /
  # `pr.merged`): they have no bus consumer that starts work, so the poll
  # cycle is what discovers the new PR or reconciles the merge.
  defp maybe_wake_on_publish(triples, opts) do
    if Enum.any?(triples, &pr_state_change_topic?/1), do: maybe_wake_orchestrator(opts)
  end

  defp pr_state_change_topic?({topic, _payload, _publish_opts}) do
    String.ends_with?(topic, ".pr.opened") or String.ends_with?(topic, ".pr.merged")
  end

  # The wake is `Orchestrator.request_refresh/0` — the SPEC §8.1 coalesced
  # immediate tick, not a fetch of its own. `request_refresh_state/1` cancels
  # the pending (possibly backed-off) timer and arms a 0ms tick, so a long
  # idle backoff is interrupted within milliseconds instead of at the next
  # scheduled interval — and because it coalesces with a poll already in
  # flight, a wake that lands mid-cycle folds into it rather than queueing a
  # second full poll. The cycle it schedules acts on state the delivery
  # already deposited (#2319); the wake itself issues no GitHub request.
  defp maybe_wake_orchestrator(opts) do
    request_refresh_fun = Keyword.get(opts, :request_refresh_fun, &Orchestrator.request_refresh/0)

    if claim_reconcile_window() do
      _ = request_refresh_fun.()
      :woke
    else
      :coalesced
    end
  end

  # A newly-opened issue is only actionable when it already carries an active
  # state label (`agent:todo` at creation). Every other `:reconcile` delivery
  # is a state change on a tracked ticket and is always actionable. The gate
  # exists so a repo opening many new, unlabelled issues cannot pin the
  # dispatcher at its base interval and delete the very idle backoff this wake
  # exists to interrupt (#2365).
  defp actionable_reconcile?(%{kind: :issue_state, action: "opened"}, payload, opts) do
    actionable_label_fun = Keyword.get(opts, :actionable_label_fun, &default_actionable_label?/1)

    payload
    |> get_in(["issue", "labels"])
    |> List.wrap()
    |> Enum.map(&(&1["name"] || ""))
    |> Enum.any?(actionable_label_fun)
  end

  defp actionable_reconcile?(_hint, _payload, _opts), do: true

  defp default_actionable_label?(label) when is_binary(label) do
    active = active_state_labels()
    prefix = GitHubConfig.label_prefix()
    Enum.any?(Issues.extract_state_labels([label], prefix), &MapSet.member?(active, &1))
  rescue
    _error -> false
  end

  defp default_actionable_label?(_label), do: false

  # Mirrors the poller's candidate filter (`Issues.filter_and_authorize_candidates`)
  # so a new issue the webhook would wake on is exactly one a poll would
  # dispatch: `StatePolicy.normalize_state/1` turns "In Progress" into
  # "in-progress", the same shape `Issues.extract_state_labels/2` derives from
  # a label like `agent:in-progress`. Fails toward an empty set so an
  # unreadable config means "not actionable" (no wake), never a wake storm.
  defp active_state_labels do
    with {:ok, settings} <- Config.settings() do
      settings.tracker.active_states
      |> Enum.map(&StatePolicy.normalize_state/1)
      |> MapSet.new()
    else
      _error -> MapSet.new()
    end
  end

  @doc false
  @spec reset_reconcile_window() :: :ok
  def reset_reconcile_window do
    :persistent_term.erase({__MODULE__, :last_reconcile_ms})
    :ok
  end

  defp claim_reconcile_window do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get({__MODULE__, :last_reconcile_ms}, nil)

    if is_integer(last) and now - last < @reconcile_debounce_ms do
      false
    else
      :persistent_term.put({__MODULE__, :last_reconcile_ms}, now)
      true
    end
  end
end
