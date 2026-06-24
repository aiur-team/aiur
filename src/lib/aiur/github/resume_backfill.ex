defmodule Aiur.GitHub.ResumeBackfill do
  @moduledoc """
  Replays a resuming ticket's existing PR discussion into the agent's
  event stream so comments posted **while the agent was offline** are
  not missed.

  The live path works: `Aiur.Events.GithubFirehose` polls GitHub and
  publishes `ticket.<id>.issue.commented` / `ticket.<id>.pr.review_comment`
  to any subscribed agent. But that poll only surfaces events created
  *after* the operator's boot (`pre_boot?` drops the rest), so a comment
  posted before the agent came online never reaches it.

  On resume — after the agent has attached its universal subscriptions
  but before the first turn — we discover the linked PR for the ticket's
  `aiur/<id>` branch, fetch its conversation + review comments, and
  publish each through `Aiur.Events.Publisher.publish/3` on the same
  topics the firehose uses. Because the agent is already subscribed,
  the Exchange delivers them exactly like a live comment.

  Each publish carries the **same `dedup_key` shape the firehose uses**,
  so if the firehose later observes the same comment within the dedup
  window it is dropped rather than delivered twice. Re-resumes after the
  window lapses may re-surface comments — preferred to silently missing
  them (see issue #485).
  """

  require Logger

  alias Aiur.Codeowners
  alias Aiur.Events.{GithubFirehose, Publisher, Sanitizer}
  alias Aiur.GitHub.Client
  alias Aiur.GitHub.Config, as: GitHubConfig

  @doc """
  Backfills offline PR comments for `identifier` (a ticket id string).
  Best-effort: any discovery/fetch failure is logged and swallowed so a
  GitHub hiccup never blocks the agent run. Returns `:ok`.

  Options (test injection):

    * `:repo` — `"owner/repo"` used for the dedup key (defaults to the
      configured repo)
    * `:pr_number` — skip PR discovery and use this number directly
    * `:request_fun` — passed through to `Aiur.GitHub.Client`
    * `:publish_fun` — overrides `Publisher.publish/3`
  """
  @spec backfill_pr_comments(String.t(), keyword()) :: :ok
  def backfill_pr_comments(identifier, opts \\ []) when is_binary(identifier) do
    case discover_pr_number(identifier, opts) do
      {:ok, nil} ->
        :ok

      {:ok, pr_number} ->
        repo = Keyword.get(opts, :repo) || GitHubConfig.repo()
        publish_fun = Keyword.get(opts, :publish_fun, &Publisher.publish/3)

        deliver(identifier, pr_number, repo, publish_fun, opts)
        :ok

      {:error, reason} ->
        Logger.warning("resume_backfill pr discovery failed identifier=#{identifier} reason=#{inspect(reason)}")

        :ok
    end
  rescue
    # Replaying already-persisted comments is best-effort: a raise in a
    # fetch, the sanitizer, or publish must never abort the agent run.
    error ->
      Logger.warning("resume_backfill crashed identifier=#{identifier} error=#{Exception.message(error)}")

      :ok
  end

  defp discover_pr_number(identifier, opts) do
    case Keyword.get(opts, :pr_number) do
      n when is_integer(n) -> {:ok, n}
      _ -> Client.fetch_open_pull_request_number_for_branch("aiur/#{identifier}", opts)
    end
  end

  defp deliver(identifier, pr_number, repo, publish_fun, opts) do
    publish_kind(
      identifier,
      repo,
      publish_fun,
      "ticket.#{identifier}.issue.commented",
      "issue_comment",
      pr_number,
      fetch(&Client.fetch_classified_issue_comments/2, pr_number, opts, identifier, "issue")
    )

    publish_kind(
      identifier,
      repo,
      publish_fun,
      "ticket.#{identifier}.pr.review_comment",
      "pr_review_comment",
      pr_number,
      fetch(&Client.fetch_classified_pr_review_comments/2, pr_number, opts, identifier, "review")
    )
  end

  defp fetch(fun, pr_number, opts, identifier, label) do
    case fun.(pr_number, opts) do
      {:ok, comments} ->
        comments

      {:error, reason} ->
        Logger.warning("resume_backfill #{label} fetch failed identifier=#{identifier} reason=#{inspect(reason)}")

        []
    end
  end

  defp publish_kind(_identifier, _repo, _publish_fun, _topic, _kind, _pr_number, []), do: :ok

  defp publish_kind(identifier, repo, publish_fun, topic, kind, pr_number, comments) do
    Enum.each(comments, fn comment ->
      author = Codeowners.comment_author(comment)

      payload =
        %{issue_number: identifier, comment: comment, source: :github}
        |> Sanitizer.scrub()
        |> Sanitizer.stamp_author_trust(actor: author)

      publish_opts = [
        actor: author,
        issue_number: identifier,
        bypass_contamination: true,
        dedup_key: GithubFirehose.comment_dedup_key(repo, kind, pr_number, Map.get(comment, "id"))
      ]

      publish_fun.(topic, payload, publish_opts)
    end)

    Logger.info("resume_backfill delivered identifier=#{identifier} topic=#{topic} count=#{length(comments)}")

    :ok
  end
end
