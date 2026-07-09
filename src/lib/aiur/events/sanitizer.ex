defmodule Aiur.Events.Sanitizer do
  alias Aiur.GitHub.CodeOwners

  @moduledoc """
  Four-layer scrub of GitHub-sourced event payloads before they reach
  any consumer (per-issue log, dashboard panel, agent digest):

    1. **Truncation** — bound user-content fields so a 50KB commit
       comment doesn't bloat every downstream surface. Commit subjects
       ≤ 200 chars; comment / PR-review bodies ≤ 500 chars; overflow
       trimmed at the nearest codepoint boundary and suffixed with `…`.
    2. **Secret-pattern redaction** — well-known credential prefixes
       (sk-, ghp_, xoxb-, github_pat_, gho_/ghu_/ghs_, AWS access keys,
       generic Stripe / Google API keys, JWT tokens) replaced with
       `[REDACTED:<pattern>]` BEFORE truncation runs, so the redacted
       match never straddles the truncation boundary.
    3. **HTML escape** — `<`, `>`, `&`, `"`, `'` escaped to entity refs
       so a comment body containing `</external-content>` can't break
       out of the wrapper the digest renderer adds at presentation
       time.
    4. **CODEOWNERS trust flag** — `author_trusted?` boolean added to
       the payload based on `Aiur.GitHub.CodeOwners.allowed?/1`. Events
       from non-CODEOWNERS authors stay visible to the operator (log +
       dashboard) but the agent-digest renderer skips them.
    5. **`<external-content>` wrapper** — applied at render time
       (see `Aiur.AgentRunner.render_events_digest/2`); not part of
       this pure module because the wrap is a presentation concern.

  Pure functions; no GenServer state. Callable from any context.

  ## Payload field paths

  GithubFirehose builds payloads with user content at nested paths,
  not as flat top-level fields. The scrubber walks each known path
  and updates in place:

  | Topic family            | Path(s) into payload                  |
  |-------------------------|---------------------------------------|
  | branch.push             | `[:commits, *, "message"]`            |
  | pr.opened / merged / …  | `[:pr, "title"]`, `[:pr, "body"]`    |
  | issue.commented         | `[:comment, "body"]`                 |
  | pr.review_comment       | `[:comment, "body"]`                 |
  | pr.review.posted        | `[:review, "body"]`                  |

  Commit subjects come from `commit["message"]` (GitHub's REST field).
  The first line is treated as the subject and capped at 200 chars;
  the full message is preserved so downstream surfaces can still
  render the body if they want.
  """

  @commit_subject_max 200
  @comment_body_max 500
  @pr_review_body_max 500

  @redaction_patterns [
    {~r/sk-[A-Za-z0-9_\-]{20,}/, "[REDACTED:sk]"},
    {~r/github_pat_[A-Za-z0-9_]{20,}/, "[REDACTED:github_pat]"},
    {~r/ghp_[A-Za-z0-9]{36,}/, "[REDACTED:ghp]"},
    {~r/gho_[A-Za-z0-9]{36,}/, "[REDACTED:gho]"},
    {~r/ghu_[A-Za-z0-9]{36,}/, "[REDACTED:ghu]"},
    {~r/ghs_[A-Za-z0-9]{36,}/, "[REDACTED:ghs]"},
    {~r/xoxb-[A-Za-z0-9-]+/, "[REDACTED:xoxb]"},
    {~r/AKIA[0-9A-Z]{16}/, "[REDACTED:aws]"},
    {~r/ASIA[0-9A-Z]{16}/, "[REDACTED:aws_session]"},
    {~r/AIza[0-9A-Za-z\-_]{35}/, "[REDACTED:google]"}
  ]

  @doc """
  Apply the redact-then-truncate-then-escape pass over a payload's
  GitHub-sourced user-content fields. Returns the sanitized payload.
  Idempotent.
  """
  @spec scrub(map()) :: map()
  def scrub(payload) when is_map(payload) do
    payload
    |> scrub_commits()
    |> scrub_pr()
    |> scrub_comment()
    |> scrub_review()
    |> scrub_ci_failure()
  end

  def scrub(other), do: other

  @doc """
  Promote a sanitized GitHub comment body to the top-level `message`
  field consumed by logs and agent event digests.
  """
  @spec put_comment_message(map()) :: map()
  def put_comment_message(%{comment: %{"body" => body}} = payload) when is_binary(body) do
    Map.put(payload, :message, body)
  end

  def put_comment_message(payload), do: payload

  @doc """
  Add an `author_trusted?` flag to the payload based on whether
  `author` (a GitHub login) is currently in the resolved CODEOWNERS
  trust set. No-op when CodeOwners isn't running (test harnesses,
  early boot) — flag is set to `false` so the conservative default is
  "filter out of agent digest".
  """
  @spec stamp_author_trust(map(), keyword()) :: map()
  def stamp_author_trust(payload, opts \\ []) when is_map(payload) do
    author = Map.get(payload, :author) || Keyword.get(opts, :actor)
    trusted? = author_trusted?(author)
    Map.put(payload, :author_trusted?, trusted?)
  end

  defp author_trusted?(nil), do: false

  defp author_trusted?(author) when is_binary(author) do
    if Process.whereis(CodeOwners) do
      CodeOwners.allowed?(author)
    else
      false
    end
  catch
    :exit, _ -> false
  end

  defp author_trusted?(_), do: false

  defp scrub_commits(%{commits: commits} = payload) when is_list(commits) do
    scrubbed = Enum.map(commits, &scrub_commit/1)
    Map.put(payload, :commits, scrubbed)
  end

  defp scrub_commits(payload), do: payload

  defp scrub_commit(commit) when is_map(commit) do
    case Map.get(commit, "message") do
      message when is_binary(message) ->
        Map.put(commit, "message", clean(message, :commit_subject))

      _ ->
        commit
    end
  end

  defp scrub_commit(other), do: other

  defp scrub_pr(%{pr: pr} = payload) when is_map(pr) do
    pr =
      pr
      |> update_string("title", &clean(&1, :commit_subject))
      |> update_string("body", &clean(&1, :comment_body))

    Map.put(payload, :pr, pr)
  end

  defp scrub_pr(payload), do: payload

  defp scrub_comment(%{comment: comment} = payload) when is_map(comment) do
    comment = update_string(comment, "body", &clean(&1, :comment_body))
    Map.put(payload, :comment, comment)
  end

  defp scrub_comment(payload), do: payload

  defp scrub_review(%{review: review} = payload) when is_map(review) do
    review = update_string(review, "body", &clean(&1, :pr_review_body))
    Map.put(payload, :review, review)
  end

  defp scrub_review(payload), do: payload

  defp scrub_ci_failure(%{failure_excerpt: excerpt} = payload) when is_binary(excerpt) do
    payload
    |> Map.put(:failure_excerpt, clean(excerpt, :comment_body))
    |> scrub_ci_checks()
  end

  defp scrub_ci_failure(payload), do: scrub_ci_checks(payload)

  defp scrub_ci_checks(%{checks: checks} = payload) when is_list(checks) do
    Map.put(payload, :checks, Enum.map(checks, &scrub_ci_check/1))
  end

  defp scrub_ci_checks(payload), do: payload

  defp scrub_ci_check(check) when is_map(check) do
    check
    |> update_atom_string(:name, &clean(&1, :commit_subject))
    |> update_atom_string(:excerpt, &clean(&1, :comment_body))
  end

  defp scrub_ci_check(check), do: check

  defp update_string(map, key, fun) do
    case Map.get(map, key) do
      value when is_binary(value) -> Map.put(map, key, fun.(value))
      _ -> map
    end
  end

  defp update_atom_string(map, key, fun) do
    case Map.get(map, key) do
      value when is_binary(value) -> Map.put(map, key, fun.(value))
      _ -> map
    end
  end

  # Single per-string pipeline: redact secrets, truncate to the field's
  # cap at a codepoint boundary, then HTML-escape so the rendered digest
  # can safely embed the content inside `<external-content>…</external-content>`
  # without an attacker breaking out via `</external-content>`.
  defp clean(text, field) when is_binary(text) do
    text
    |> redact()
    |> truncate(field)
    |> html_escape()
  end

  defp redact(text) when is_binary(text) do
    Enum.reduce(@redaction_patterns, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  defp truncate(text, :commit_subject), do: codepoint_truncate(text, @commit_subject_max)
  defp truncate(text, :comment_body), do: codepoint_truncate(text, @comment_body_max)
  defp truncate(text, :pr_review_body), do: codepoint_truncate(text, @pr_review_body_max)

  defp codepoint_truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "…"
    else
      text
    end
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
