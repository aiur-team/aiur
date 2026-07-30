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

    * `bot_account` (from `Aiur.GitHub.Config.bot_account/0`) and
      `trusted_accounts` (from `Aiur.GitHub.Config.trusted_accounts/0`)
      are **always** included regardless of CODEOWNERS contents.
    * Missing or empty CODEOWNERS file → allowlist contains only the
      explicitly configured trusted accounts.
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

  @doc """
  Returns the current comment-trust snapshot, including whether trust comes
  from a parsed CODEOWNERS file or the safe repository-owner fallback.
  """
  @spec trust_snapshot(GenServer.server()) :: map()
  def trust_snapshot(server \\ __MODULE__) do
    GenServer.call(server, :trust_snapshot)
  end

  @doc false
  @spec codeowners_snapshot(GenServer.server()) :: [String.t()]
  def codeowners_snapshot(server \\ __MODULE__) do
    GenServer.call(server, :codeowners_snapshot)
  end

  @impl true
  def init(opts) do
    state = %{
      # Sentinel so the size==0 guard in do_refresh never silently
      # preserves an actually-empty allowlist. allowed?/1 never matches
      # this sentinel because it's not a valid GitHub login.
      allowlist: MapSet.new(["__codeowners_bootstrap__"]),
      codeowners: MapSet.new(),
      codeowners_path: Keyword.get(opts, :path, default_codeowners_path()),
      request_fun: Keyword.get(opts, :request_fun),
      allowed_users_fun: Keyword.get(opts, :allowed_users_fun, &configured_allowed_users/0),
      alert_fun: Keyword.get(opts, :alert_fun, &Aiur.Alerts.emit_custom/3),
      refresh_seconds: Keyword.get(opts, :refresh_seconds, @default_refresh_seconds),
      timer_ref: nil,
      empty_alerted: false,
      degradation: nil,
      degradation_alerted: nil,
      trust_source: :bootstrap,
      drift: nil
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

  def handle_call(:codeowners_snapshot, _from, state) do
    {:reply, sorted_logins(state.codeowners), state}
  end

  def handle_call(:trust_snapshot, _from, state) do
    {:reply, trust_snapshot_map(state), state}
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
    trusted_set = trusted_account_set()
    {tokens, degradation} = parse_codeowners(state.codeowners_path)

    if degradation do
      Logger.warning("CodeOwners: CODEOWNERS degradation=#{inspect(degradation)} path=#{state.codeowners_path}")
    end

    resolved = if degradation, do: MapSet.new(), else: resolve_tokens(tokens, state.request_fun)

    new_allowlist = MapSet.union(resolved, trusted_set)
    state = maybe_alert_degradation(state, degradation)
    state = compare_allowed_users(state, resolved)

    if MapSet.size(new_allowlist) > 0 do
      %{
        state
        | allowlist: new_allowlist,
          codeowners: resolved,
          empty_alerted: false,
          degradation: degradation,
          trust_source: if(degradation, do: :fallback, else: :file)
      }
    else
      # No CODEOWNERS entries and no bot_account/trusted_accounts. Rather than
      # silently trust nobody — which disables the whole review-comment → rework
      # loop (#693) by dropping every comment as :untrusted_author — fall back to
      # the repo owner (inherently trusted, unlike an arbitrary third party per
      # #687) and surface the gap loudly so the Executor sets CODEOWNERS /
      # trusted_accounts.
      owner = repo_owner_login()
      state = maybe_alert_empty_allowlist(state, owner)

      case owner do
        owner when is_binary(owner) ->
          %{
            state
            | allowlist: MapSet.new([owner]),
              codeowners: resolved,
              degradation: degradation,
              trust_source: :fallback
          }

        _ ->
          Logger.error(
            "CodeOwners: trust allowlist is empty and repo owner is unknown; " <>
              "keeping previous allowlist (review-comment trust disabled)"
          )

          %{
            state
            | codeowners: resolved,
              degradation: degradation,
              trust_source: :fallback
          }
      end
    end
  end

  defp maybe_alert_degradation(state, nil), do: %{state | degradation_alerted: nil}

  defp maybe_alert_degradation(%{degradation_alerted: degradation} = state, degradation), do: state

  defp maybe_alert_degradation(state, degradation) do
    message =
      case degradation do
        :missing -> "CODEOWNERS is missing"
        :empty -> "CODEOWNERS is empty"
        {:unparseable, line} -> "CODEOWNERS is unparseable near line #{line}"
      end

    state.alert_fun.(
      "github.codeowners.degraded",
      "#{message} at #{state.codeowners_path}; comment trust is using the safe fallback.",
      reason: "CODEOWNERS degradation: #{message}",
      needs_attention: true,
      severity: "warning"
    )

    %{state | degradation_alerted: degradation}
  end

  defp compare_allowed_users(state, codeowners) do
    configured = state.allowed_users_fun.()

    if is_list(configured) do
      configured = normalize_logins(configured)
      codeowners = normalize_logins(MapSet.to_list(codeowners))

      if MapSet.size(configured) == 0 do
        %{state | drift: nil}
      else
        drift = if MapSet.equal?(configured, codeowners), do: nil, else: {codeowners, configured}

        if drift && state.drift != drift do
          {owners, allowed_users} = drift

          state.alert_fun.(
            "github.codeowners.allowlist_drift",
            "CODEOWNERS trust #{format_logins(owners)} diverges from dispatch allowed_users #{format_logins(allowed_users)}.",
            reason: "CODEOWNERS and tracker.allowed_users must converge",
            needs_attention: true,
            severity: "warning"
          )
        end

        %{state | drift: drift}
      end
    else
      %{state | drift: nil}
    end
  end

  defp configured_allowed_users do
    case Aiur.Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        case get_in(config, ["tracker", "github", "allowed_users"]) do
          users when is_list(users) ->
            if MapSet.size(normalize_logins(users)) > 0, do: users, else: nil

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp trust_snapshot_map(state) do
    %{
      trusted: sorted_logins(state.allowlist),
      codeowners: sorted_logins(state.codeowners),
      source: state.trust_source,
      path: state.codeowners_path,
      degradation: state.degradation,
      drift: state.drift
    }
  end

  defp normalize_logins(logins) do
    logins
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp sorted_logins(logins), do: logins |> MapSet.new() |> MapSet.to_list() |> Enum.sort()

  defp format_logins(logins), do: logins |> sorted_logins() |> Enum.map_join(", ", &"@#{&1}") |> then(&"[#{&1}]")

  # Repo owner login from `owner/name`, lowercased; nil when unknown.
  defp repo_owner_login do
    with repo when is_binary(repo) <- Config.repo(),
         [owner, _name] <- String.split(repo, "/", parts: 2),
         trimmed when trimmed != "" <- String.trim(owner) do
      String.downcase(trimmed)
    else
      _ -> nil
    end
  end

  # One-shot needs_attention alert the first time the allowlist resolves empty,
  # so the degraded review-comment feature is visible instead of silently
  # dropping comments. Reset to re-armable once a real allowlist is configured
  # (the size>0 branch sets empty_alerted: false).
  defp maybe_alert_empty_allowlist(%{empty_alerted: true} = state, _owner), do: state

  defp maybe_alert_empty_allowlist(state, owner) do
    detail =
      if is_binary(owner),
        do: "falling back to repo owner @#{owner}",
        else: "no repo owner could be derived; review comments are NOT trusted"

    state.alert_fun.(
      "github.codeowners.allowlist_empty",
      "Comment-trust allowlist is empty (no .github/CODEOWNERS and no bot_account/trusted_accounts) — " <>
        detail <> ". Set CODEOWNERS or trusted_accounts so review comments drive rework.",
      needs_attention: true,
      severity: "warning"
    )

    %{state | empty_alerted: true}
  end

  defp trusted_account_set do
    [Config.bot_account() | Config.trusted_accounts()]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp default_codeowners_path do
    Aiur.Codeowners.file_path() ||
      Path.join(File.cwd!(), hd(Aiur.Codeowners.standard_paths()))
  end

  defp parse_codeowners(path) do
    case File.read(path) do
      {:ok, content} ->
        meaningful =
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.reject(fn {line, _number} -> comment_or_empty?(line) end)

        cond do
          meaningful == [] ->
            {[], :empty}

          Enum.any?(meaningful, fn {line, _number} -> not parsable_line?(line) end) ->
            {[], {:unparseable, first_unparseable_line(meaningful)}}

          true ->
            {meaningful |> Enum.flat_map(fn {line, _number} -> tokens_on_line(line) end) |> Enum.uniq(), nil}
        end

      {:error, _} ->
        {[], :missing}
    end
  end

  defp parsable_line?(line) do
    tokens = String.split(line, ~r/\s+/, trim: true)
    length(tokens) >= 2 and Enum.all?(Enum.drop(tokens, 1), &valid_owner_token?/1)
  end

  defp first_unparseable_line(lines) do
    lines
    |> Enum.find_value(fn {line, number} -> if parsable_line?(line), do: nil, else: number end)
  end

  defp valid_owner_token?("@" <> rest), do: rest != ""
  defp valid_owner_token?(token), do: String.contains?(token, "@")

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
