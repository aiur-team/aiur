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
  CI outcomes, `synchronize`) do not publish here. They nudge the orchestrator
  to run its poll cycle now, so the *existing* producer emits the *existing*
  event without a poll-interval wait. Consecutive nudges are coalesced.

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

  alias Aiur.Events.GithubWebhook.{Deposit, Normalizer, ThreadResolver}
  alias Aiur.Events.{Publisher, Sanitizer}
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
    * `:reconcile_fun` — 1-arity override for the orchestrator nudge
    * `:orchestrator` — process name or pid to nudge; defaults to
      `Aiur.Orchestrator`
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
        publish_all(triples, opts)

      {:reconcile, hint} ->
        hint = with_reconcile_generation(hint, opts)
        request_reconcile(hint, opts)
        %{status: :reconciled, hint: hint}

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
        Deposit.deposit(event_type, payload, repo, Keyword.take(opts, [:delivery_id]))
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
      {:ok, repo} -> resolve_review_thread(payload, repo, opts)
      _untracked_or_malformed -> payload
    end
  end

  defp maybe_resolve_review_thread(_event_type, payload, _opts), do: payload

  # Best-effort resolution of the comment's thread id: a delivery with no
  # `node_id`, or a lookup that fails, falls through to the per-comment key the
  # normalizer already uses — a duplicate wake is recoverable, a dropped
  # delivery is not.
  #
  # The resolver is handed the delivery's repo and the comment's REST `id`
  # (its `databaseId`) so it can consult the comment→thread map the poller's
  # batch already built before spending a GraphQL point (#2326).
  defp resolve_review_thread(payload, repo, opts) do
    comment = Map.get(payload, "comment")

    resolver_opts =
      opts
      |> Keyword.put(:repo, repo)
      |> Keyword.put(:comment_id, Map.get(comment, "id"))

    with node_id when is_binary(node_id) and node_id != "" <- Map.get(comment, "node_id"),
         {:ok, thread_id} <- ThreadResolver.resolve(node_id, resolver_opts) do
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
  # poll cycle. `Lifecycle.schedule_tick/2` cancels the pending timer before
  # arming a new one, so an extra `:run_poll_cycle` reschedules rather than
  # compounding — but a delivery burst would still spin the cycle, so nudges
  # are coalesced into one per debounce window.
  defp request_reconcile(hint, opts) do
    case Keyword.get(opts, :reconcile_fun) do
      fun when is_function(fun, 1) -> fun.(hint)
      _other -> nudge_orchestrator(hint, Keyword.get(opts, :orchestrator, Aiur.Orchestrator))
    end
  end

  defp nudge_orchestrator(%{kind: :review_thread} = hint, target) do
    case resolve_orchestrator(target) do
      pid when is_pid(pid) -> send(pid, {:github_webhook_reconcile, hint})
      nil -> :ok
    end
  end

  defp nudge_orchestrator(_hint, target) do
    case resolve_orchestrator(target) do
      pid when is_pid(pid) ->
        if claim_reconcile_window() do
          send(pid, :run_poll_cycle)
          :ok
        else
          :coalesced
        end

      nil ->
        :ok
    end
  end

  defp with_reconcile_generation(%{kind: :review_thread, generation: generation} = hint, opts)
       when not (is_binary(generation) and generation != "") do
    Map.put(hint, :generation, Keyword.get(opts, :delivery_id))
  end

  defp with_reconcile_generation(hint, _opts), do: hint

  defp resolve_orchestrator(pid) when is_pid(pid), do: pid
  defp resolve_orchestrator(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_orchestrator(_target), do: nil

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
