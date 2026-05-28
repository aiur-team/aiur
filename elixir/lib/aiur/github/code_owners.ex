defmodule Aiur.GitHub.CodeOwners do
  @moduledoc """
  GitHub CODEOWNERS-based author allowlist for the events sanitization
  pipeline.

  ## Purpose

  Untrusted GitHub commenters can stuff prompt-injection payloads into
  issue bodies, PR descriptions, review comments, and commit messages.
  Aiur agents read these surfaces verbatim when an event arrives, so we
  pre-filter every author through the repository's CODEOWNERS file —
  events authored by anyone not on that allowlist get their body
  dropped (the structural metadata still flows: who/when/what action,
  not what they said).

  This is the structural defense layer; secret regex + `<external-content>`
  framing layer the prompt isolation on top.

  ## Fail-closed semantics

  Empty allowlist would let everyone through (the empty-set predicate
  is `false` for every member, so the *complement* would be "deny all"
  — which would in practice drop every PR comment, including Aiur's
  own bot-account replies, and the orchestrator would lock itself out
  of the dependencies dance). To prevent that:

    * `bot_account` (from `Aiur.GitHub.Config.bot_account/0`) is
      **always** included regardless of CODEOWNERS contents.
    * Missing or empty CODEOWNERS file → allowlist is `MapSet.new([bot_account])`
      (and a critical warning is logged).
    * Failure to resolve a team/org → log + skip that token; do NOT
      raise (one broken entry should not block the rest).

  ## Refresh

  Every `events.codeowners_refresh_seconds` (default 3600s) the GenServer
  re-parses the file and re-resolves teams/orgs. Resolution failures
  preserve the previous allowlist rather than dropping to bot-only —
  transient API hiccups must not cause every event body to suddenly
  disappear.

  ## Token forms supported

    * `@username` — single GitHub login
    * `@org/team-slug` — expanded via `GET /orgs/{org}/teams/{team}/members`
    * `@org` — expanded via `GET /orgs/{org}/members`

  Email-style entries (`user@example.com`) and glob patterns (`*.ex`)
  are parsed but ignored for the allowlist (CODEOWNERS uses globs to
  scope ownership to file paths; the events pipeline only cares about
  who is *ever* an owner of anything in the repo).
  """

  use GenServer

  require Logger

  alias Aiur.GitHub.{Client, Config}

  @default_refresh_seconds 3_600

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns true iff `author` is in the current allowlist. Case-insensitive
  on the GitHub login.
  """
  @spec allowed?(String.t() | nil, GenServer.server()) :: boolean()
  def allowed?(author, server \\ __MODULE__)

  def allowed?(nil, _server), do: false

  def allowed?(author, server) when is_binary(author) do
    GenServer.call(server, {:allowed?, String.downcase(author)})
  end

  @doc """
  Forces an immediate refresh. Mostly for tests; the scheduled refresh
  on the configured interval is what runs in production.
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh, 30_000)
  end

  @doc """
  Returns the current allowlist (lowercased logins) as a list. For tests
  and observability.
  """
  @spec snapshot(GenServer.server()) :: [String.t()]
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    state = %{
      # Sentinel so the size==0 guard in do_refresh never silently
      # preserves an actually-empty allowlist. allowed?/1 never matches
      # this sentinel because it's not a valid GitHub login.
      allowlist: MapSet.new(["__codeowners_bootstrap__"]),
      codeowners_path: Keyword.get(opts, :path, default_codeowners_path()),
      request_fun: Keyword.get(opts, :request_fun),
      refresh_seconds: Keyword.get(opts, :refresh_seconds, @default_refresh_seconds),
      timer_ref: nil
    }

    {:ok, state, {:continue, :initial_refresh}}
  end

  @impl true
  def handle_continue(:initial_refresh, state) do
    state = do_refresh(state)
    {:noreply, schedule_next_refresh(state)}
  end

  @impl true
  def handle_call({:allowed?, author_down}, _from, state) do
    {:reply, MapSet.member?(state.allowlist, author_down), state}
  end

  def handle_call(:refresh, _from, state) do
    state = do_refresh(state)
    {:reply, :ok, schedule_next_refresh(state)}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, MapSet.to_list(state.allowlist), state}
  end

  @impl true
  def handle_info(:refresh_tick, state) do
    state = do_refresh(state)
    {:noreply, schedule_next_refresh(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_next_refresh(state) do
    if is_reference(state.timer_ref), do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :refresh_tick, state.refresh_seconds * 1_000)
    %{state | timer_ref: ref}
  end

  defp do_refresh(state) do
    bot_set = bot_set()
    tokens = parse_codeowners(state.codeowners_path)

    resolved =
      case tokens do
        [] ->
          Logger.warning(
            "CodeOwners: file missing or empty at #{state.codeowners_path}; " <>
              "allowlist reduced to bot-only"
          )

          MapSet.new()

        _ ->
          resolve_tokens(tokens, state.request_fun)
      end

    new_allowlist = MapSet.union(resolved, bot_set)

    if MapSet.size(new_allowlist) == 0 do
      Logger.error("CodeOwners: allowlist would be empty (bot_account also unset); keeping previous allowlist")

      state
    else
      %{state | allowlist: new_allowlist}
    end
  end

  defp bot_set do
    case Config.bot_account() do
      bot when is_binary(bot) -> MapSet.new([String.downcase(bot)])
      _ -> MapSet.new()
    end
  end

  defp default_codeowners_path do
    Enum.find_value(
      [".github/CODEOWNERS", "docs/CODEOWNERS", "CODEOWNERS"],
      fn rel ->
        path = Path.join(File.cwd!(), rel)
        if File.regular?(path), do: path
      end
    ) || Path.join(File.cwd!(), ".github/CODEOWNERS")
  end

  defp parse_codeowners(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reject(&comment_or_empty?/1)
        |> Enum.flat_map(&tokens_on_line/1)
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  defp comment_or_empty?(line) do
    trimmed = String.trim(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  defp tokens_on_line(line) do
    line
    |> String.split(~r/\s+/, trim: true)
    # Drop the path pattern (first token); the rest are owner tokens
    |> Enum.drop(1)
    |> Enum.filter(&String.starts_with?(&1, "@"))
  end

  defp resolve_tokens(tokens, request_fun) do
    tokens
    |> Enum.flat_map(&resolve_token(&1, request_fun))
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp resolve_token("@" <> rest, request_fun) do
    case String.split(rest, "/", parts: 2) do
      [user] when user != "" ->
        [user]

      [org, team] when org != "" and team != "" ->
        resolve_team(org, team, request_fun)

      _ ->
        []
    end
  end

  defp resolve_team(org, team, request_fun) do
    opts = if is_function(request_fun, 1), do: [request_fun: request_fun], else: []

    case Client.fetch_team_members(org, team, opts) do
      {:ok, logins} ->
        logins

      {:error, reason} ->
        Logger.warning("CodeOwners: failed to resolve @#{org}/#{team}: #{inspect(reason)}")
        []
    end
  end
end
