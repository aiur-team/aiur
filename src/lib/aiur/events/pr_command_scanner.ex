defmodule Aiur.Events.PrCommandScanner do
  @moduledoc """
  Pure detection of one-off PR comment commands for repo-wide opt-in
  watching (the U3 trigger). No HTTP, no GenServer state — given an
  already-fetched, trust-stamped list of comments it returns only the
  comments that are *trusted commands*.

  A comment is a command when its trimmed body **starts with** the
  configured command prefix (e.g. `/aiur …`) OR **mentions** the
  configured bot account (`@<daemon_account>`, word-boundary,
  case-insensitive on the login). The bot-mention match deliberately
  uses a word boundary so `@aiur` (a real, unrelated GitHub user) never
  matches a bot account of `aiur-bot`, and a login that is merely a
  prefix of the configured bot (`@aiur` vs bot `aiur-bot`) does not
  false-match.

  A command is only acted on when ALL of these hold:

    1. The marker (prefix or mention) is present.
    2. The author is trusted — the `author_trusted?` flag already
       stamped by `Aiur.Events.Sanitizer.stamp_author_trust/2` from the
       CODEOWNERS ∪ Aiur's own logins ∪ `trusted_accounts` set. This module
       does NOT re-derive trust; it consumes the flag.
    3. The comment is NOT Aiur's own — Aiur's `/aiur`/mention comments are
       dropped to avoid a self-loop (mirrors
       `Aiur.Events.Publisher.bot_self_loop?/1`, which keys on the
       comment author so a *human* mentioning the bot still passes).
       In single-account mode (#2501) the author login cannot answer this,
       so it is answered by `Aiur.GitHub.AgentMarker` instead.

  ## Comment shape

  Each comment is a map carrying at least:

    * an author login at `["user", "login"]` (REST issue/PR comments) or
      `["author", "login"]` (GraphQL review-thread comments)
    * a `"body"` string
    * an `author_trusted?` boolean (stamped upstream)
  """

  alias Aiur.GitHub.AgentMarker
  alias Aiur.GitHub.Config, as: GitHubConfig

  @typedoc """
  A GitHub comment map with an author login, a `"body"`, and an
  `author_trusted?` flag stamped by the sanitizer.
  """
  @type comment :: map()

  @doc """
  Returns the subset of `comments` that are trusted one-off commands for
  `command_prefix` / `daemon_account`.

  `command_prefix` is the literal leading marker (e.g. `"/aiur"`).
  `daemon_account` is the configured bot login (nil disables mention
  matching but leaves prefix matching intact). A `nil`/blank
  `command_prefix` disables prefix matching.
  """
  @spec commands([comment()], String.t() | nil, String.t() | nil) :: [comment()]
  def commands(comments, command_prefix, daemon_account) when is_list(comments) do
    Enum.filter(comments, &command?(&1, command_prefix, daemon_account))
  end

  @doc """
  Whether a single `comment` is a trusted one-off command.

  Untrusted authors, the bot's own comments, and comments with no marker
  all return `false`.
  """
  @spec command?(comment(), String.t() | nil, String.t() | nil) :: boolean()
  def command?(comment, command_prefix, daemon_account) when is_map(comment) do
    author = comment_author(comment)
    body = comment_body(comment)

    trusted?(comment) and
      not aiur_authored?(author, daemon_account, body) and
      command_body?(body, command_prefix, daemon_account)
  end

  def command?(_comment, _command_prefix, _daemon_account), do: false

  @doc """
  Whether a raw comment `body` carries a command marker — a leading
  `command_prefix` or a word-boundary `@<daemon_account>` mention. Pure
  string check with no trust/author gating; the public gate is
  `command?/3`.
  """
  @spec command_body?(String.t() | nil, String.t() | nil, String.t() | nil) :: boolean()
  def command_body?(body, command_prefix, daemon_account) when is_binary(body) do
    starts_with_prefix?(body, command_prefix) or mentions_bot?(body, daemon_account)
  end

  def command_body?(_body, _command_prefix, _daemon_account), do: false

  defp starts_with_prefix?(body, prefix) when is_binary(prefix) do
    case String.trim(prefix) do
      "" -> false
      trimmed_prefix -> String.starts_with?(String.trim_leading(body), trimmed_prefix)
    end
  end

  defp starts_with_prefix?(_body, _prefix), do: false

  # Word-boundary, case-insensitive mention match. The negative lookahead
  # on a trailing word char keeps `@aiur-bot` from matching a configured
  # bot of `@aiur`, and the leading boundary keeps `foo@aiur` (an email
  # tail) from matching. The login is regex-escaped so a login with
  # regex metacharacters can't break the pattern.
  defp mentions_bot?(body, daemon_account) when is_binary(daemon_account) do
    case String.trim(daemon_account) do
      "" ->
        false

      login ->
        pattern = ~r/(^|[^A-Za-z0-9_\/-])@#{Regex.escape(login)}(?![A-Za-z0-9_-])/i
        Regex.match?(pattern, body)
    end
  end

  defp mentions_bot?(_body, _daemon_account), do: false

  defp trusted?(%{author_trusted?: true}), do: true
  defp trusted?(%{"author_trusted?" => true}), do: true
  defp trusted?(_comment), do: false

  # The self-loop drop, mode-aware for the same reason the publisher's is
  # (#2501): in single-account mode the operator types `/aiur` under the very
  # login the daemon writes as, so dropping on the login alone would make the
  # command surface unusable for exactly the operator it exists for.
  #
  # Presence of the marker, never its absence: an unmarked `/aiur` comment is
  # obeyed. The worst case is Aiur acting on a command it wrote, which is
  # already bounded by the trust gate above; the alternative is an operator's
  # command silently ignored.
  defp aiur_authored?(author, daemon_account, body) do
    bot_author?(author, daemon_account) and
      (not GitHubConfig.single_account?() or AgentMarker.marked?(body))
  end

  defp bot_author?(author, daemon_account)
       when is_binary(author) and is_binary(daemon_account) do
    String.downcase(String.trim(author)) == String.downcase(String.trim(daemon_account))
  end

  defp bot_author?(_author, _daemon_account), do: false

  defp comment_author(comment) when is_map(comment) do
    get_in(comment, ["user", "login"]) ||
      get_in(comment, ["author", "login"]) ||
      Map.get(comment, :author)
  end

  defp comment_body(comment) when is_map(comment) do
    case Map.get(comment, "body") do
      body when is_binary(body) -> body
      _ -> nil
    end
  end
end
