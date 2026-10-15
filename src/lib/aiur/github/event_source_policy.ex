defmodule Aiur.GitHub.EventSourcePolicy do
  @moduledoc "GitHub provenance, resource deduplication and webhook corroboration for event publication."
  @behaviour Aiur.Events.SourcePolicy

  alias Aiur.GitHub.AgentMarker
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Webhooks

  # Corroboration for the webhook silence sweep: the poller observed a GitHub
  # resource for this repo that **no webhook had already accounted for**.
  #
  # Two gate families sit in `rejection/3` and they mean opposite things here.
  # The *filter* gates (`filtered_bot_self_loop?`, `tracked?`) say "this fleet
  # does not act on this event" — the event still happened, and since this
  # fleet's traffic is mostly agent-authored, ignoring them would let ingress
  # die without ever accumulating corroboration: no degradation, no alert,
  # silence indistinguishable from health. The *dedup* gates say something
  # entirely different — "this is the same event again" — and those must never
  # count as evidence.
  #
  # The distinction is load-bearing because the poller is publish-and-reject
  # with no pre-check against the store, so it re-offers old resources on every
  # sweep, forever: `advance_since/2` rewinds its watermark by a second, a
  # `304` republishes the whole cached comment list, and unaddressed PR review
  # threads have no cursor at all. Counting those would march
  # `last_activity_at` forward on a repo where nothing happened while
  # `last_delivery_at` stood still, degrading a healthy webhook after one
  # threshold. The separation rule in `delivery_was_owed?/2` cannot catch it,
  # because a re-observed event is arbitrarily old and the gap is unbounded.
  #
  # Whether an observation is *new* is decided by the registry, not here, and
  # deliberately not from `resource_processed?/1` or the dedup window. Both are
  # written only by `do_publish/3`, so neither ever records filtered traffic —
  # and filtered traffic is precisely what this recorder exists to carry.
  # Inferring novelty from a store the path never writes to was the mistake;
  # the registry keys on the resource itself, which every path supplies.
  # Review-thread comments deliberately share one resource key, and edits reuse
  # it because resource versions are excluded from observations; both can only
  # under-count corroboration, never manufacture evidence that did not happen.
  #
  # `deduped?/1` is still honoured through `outcome`, because it catches a
  # replay keyed to a resource the registry has not seen. It is not re-checked:
  # it claims into an ETS window as a side effect, so a second call would
  # answer itself.
  #
  # Reordering `rejection/3` was the other way to separate the gate families,
  # and was rejected: `deduped?/1` must be evaluated exactly once, and
  # `Aiur.Orchestrator.CiLifecycle` branches on `:deduped`, so changing which
  # reason wins for an event matching both families changes real behaviour.
  #
  # The repo comes from the resource key rather than `Aiur.GitHub.Config.repo/0`
  # for three reasons: the key already carries it, it is already downcased to
  # the registry's canonical form, and reading config here would both shell out
  # to `git remote` on every polled publish and risk an `ArgumentError` that
  # `Webhooks.record_activity/3` does not catch — it catches exits, not raises.
  @impl true
  def observe(:deduped, _opts), do: :ok

  def observe(_outcome, opts) do
    with {_type, owner, repo, _id} = resource <- Keyword.get(opts, :resource),
         :poll <- Keyword.fetch!(opts, :resource_source) do
      Webhooks.record_activity("#{owner}/#{repo}", observation: resource)
    else
      _not_a_polled_github_resource -> :ok
    end
  end

  @impl true
  def already_processed?(opts) do
    ResourceStore.processed?(Keyword.get(opts, :resource), Keyword.get(opts, :resource_version))
  end

  @impl true
  def mark_processed(opts) do
    ResourceStore.mark_processed(
      Keyword.get(opts, :resource),
      Keyword.get(opts, :resource_source, :poll),
      Keyword.get(opts, :resource_version)
    )
  end

  defp bot_self_loop?(nil), do: false

  defp bot_self_loop?(actor) when is_binary(actor) do
    # The daemon identity, not the agent one: this drops events the daemon
    # itself produced. An agent's write is a real external event the daemon
    # must react to, so it deliberately does not match here.
    case GitHubConfig.daemon_account() do
      bot when is_binary(bot) -> String.downcase(actor) == String.downcase(bot)
      _ -> false
    end
  end

  defp authoritative_merge_topic?(topic), do: String.ends_with?(topic, ".pr.merged")

  @impl true
  def self_authored?(topic, actor, payload),
    do:
      bot_self_loop?(actor) and not authoritative_merge_topic?(topic) and
        ours_by_provenance?(payload)

  # Separate-account mode: the author login *is* the proof, so nothing further
  # is asked and every gate decision is byte-for-byte what it was before.
  #
  # Single-account mode: the login proves nothing, because the operator holds
  # it too. For an event that carries a comment body — the only events a human
  # can author from that login and the only ones this ticket is about — the
  # proof must come from the body, so suppression requires the marker Aiur
  # stamps on what it writes. An unmarked body publishes and wakes the agent,
  # which is the intended cost: a redundant wake is recoverable, while dropping
  # an operator's instruction is silent.
  #
  # Note the direction. This never suppresses on the *absence* of a human
  # signal; it suppresses only on the *presence* of Aiur's own. So a comment
  # posted before the marker existed reads as human, not as ours.
  #
  # THREE cases, not two. "This event carries no comment at all" and "this
  # event carries a comment whose body I could not read" are different facts
  # and must not collapse into one:
  #
  #   * `:no_comment` — a push, a label change, a CI result. Login-based
  #     suppression in both modes: a human cannot hand-author these into the
  #     daemon's own event stream, so there is no ambiguity for a marker to
  #     resolve, and demanding one would republish every self-emitted event on
  #     a single-account install.
  #   * `{:body, text}` — decide from the marker.
  #   * `:unreadable` — a comment key is present but its body is not a string.
  #     This is REACHABLE, not defensive: `GithubCommentsPoller`'s
  #     `publish_pr_review_submission/5` puts the raw REST review object under
  #     `:comment`, and `actionable_review?/1` passes a CHANGES_REQUESTED
  #     review without inspecting its body, which GitHub returns as `null` when
  #     the reviewer left only inline comments. Treating that as ours swallowed
  #     an operator's request for changes — and since #2473 the body-only
  #     CHANGES_REQUESTED review is the load-bearing rework signal when there
  #     are no threads, so nothing downstream would have caught it. Unreadable
  #     means human.
  defp ours_by_provenance?(payload) do
    case comment_provenance(payload) do
      :no_comment -> true
      :unreadable -> not GitHubConfig.single_account?()
      {:body, body} -> not GitHubConfig.single_account?() or AgentMarker.marked?(body)
    end
  end

  # `Aiur.Events.Sanitizer` deletes HTML comments as hidden-instruction
  # carriers, so on any path that sanitizes before publishing (notably
  # `Aiur.Orchestrator.CommandScan`) the marker is already gone from the body by
  # the time this runs. The sanitizer therefore records what it saw *before*
  # stripping, and that record is consulted first. Its absence proves nothing
  # and falls through to the body, which in turn fails to human.
  defp comment_provenance(payload) do
    case aiur_authored_flag(payload) do
      true -> {:body, AgentMarker.marker()}
      false -> :unreadable
      nil -> comment_body_provenance(payload)
    end
  end

  defp aiur_authored_flag(%{aiur_authored?: flag}) when is_boolean(flag), do: flag
  defp aiur_authored_flag(_payload), do: nil

  defp comment_body_provenance(%{comment: comment}), do: body_provenance(comment)
  defp comment_body_provenance(%{"comment" => comment}), do: body_provenance(comment)
  defp comment_body_provenance(_payload), do: :no_comment

  defp body_provenance(comment) when is_map(comment) do
    case Map.get(comment, "body") do
      body when is_binary(body) -> {:body, body}
      _unreadable -> :unreadable
    end
  end

  defp body_provenance(_comment), do: :unreadable
end
