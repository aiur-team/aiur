defmodule Aiur.GitHub.CodeOwners do
  @moduledoc """
  Single comment-trust snapshot. Every refresh trusts configured identities,
  the repository owner, direct CODEOWNERS logins and successfully resolved
  teams. Failed lookups never retain previous team membership.
  """

  use GenServer

  alias Aiur.GitHub.{CodeownersFile, Teams, TrustSnapshot}

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

  @doc "Configured identities and repository owner trusted without CODEOWNERS."
  defdelegate configured_set(), to: TrustSnapshot

  @doc "Status-line suffix naming a degraded snapshot's cause and age."
  defdelegate status_suffix(snapshot, now \\ DateTime.utc_now()), to: TrustSnapshot

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
      allowlist: MapSet.new(),
      codeowners: MapSet.new(),
      codeowners_path: Keyword.get(opts, :path, default_codeowners_path()),
      request_fun: Keyword.get(opts, :request_fun),
      allowed_users_fun: Keyword.get(opts, :allowed_users_fun, &configured_allowed_users/0),
      alert_fun: Keyword.get(opts, :alert_fun, &Aiur.Alerts.emit_custom/3),
      refresh_seconds: Keyword.get(opts, :refresh_seconds, @default_refresh_seconds),
      timer_ref: nil,
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
    {resolved, cause} = resolve_file(state.codeowners_path, state.request_fun)
    cause = cause || if(TrustSnapshot.repo_owner() == nil, do: :repo_owner_unknown)
    degradation = TrustSnapshot.degradation(state.degradation, cause)
    state = maybe_alert_degradation(state, degradation)
    state = compare_allowed_users_if_healthy(state, cause, resolved)

    %{
      state
      | allowlist: MapSet.union(resolved, TrustSnapshot.configured_set()),
        codeowners: resolved,
        degradation: degradation,
        trust_source: if(cause, do: :fallback, else: :file)
    }
  end

  defp maybe_alert_degradation(state, nil), do: %{state | degradation_alerted: nil}

  defp maybe_alert_degradation(%{degradation_alerted: cause} = state, %{cause: cause}), do: state

  defp maybe_alert_degradation(state, %{cause: cause} = degradation) do
    state.alert_fun.(
      "github.codeowners.degraded",
      "#{TrustSnapshot.description(cause)} at #{state.codeowners_path}; #{TrustSnapshot.age_label(degradation)}; comment trust uses only verified accounts.",
      reason: "CODEOWNERS trust degraded: #{inspect(cause)}",
      needs_attention: true,
      severity: "warning"
    )

    %{state | degradation_alerted: cause}
  end

  defp compare_allowed_users(state, codeowners) do
    case state.allowed_users_fun.() do
      configured when is_list(configured) ->
        compare_configured_allowed_users(state, configured, codeowners)

      _ ->
        %{state | drift: nil}
    end
  end

  defp compare_allowed_users_if_healthy(state, nil, codeowners),
    do: compare_allowed_users(state, codeowners)

  defp compare_allowed_users_if_healthy(state, _degradation, _codeowners), do: %{state | drift: nil}

  defp compare_configured_allowed_users(state, configured, codeowners) do
    configured = normalize_logins(configured)
    codeowners = normalize_logins(MapSet.to_list(codeowners))

    if MapSet.size(configured) == 0 do
      %{state | drift: nil}
    else
      drift = if MapSet.equal?(configured, codeowners), do: nil, else: {codeowners, configured}
      maybe_alert_drift(state, drift)
    end
  end

  defp maybe_alert_drift(%{drift: drift} = state, drift), do: state

  defp maybe_alert_drift(state, nil), do: %{state | drift: nil}

  defp maybe_alert_drift(state, {owners, allowed_users} = drift) do
    state.alert_fun.(
      "github.codeowners.allowlist_drift",
      "CODEOWNERS trust #{format_logins(owners)} diverges from dispatch allowed_users #{format_logins(allowed_users)}.",
      reason: "CODEOWNERS and tracker.allowed_users must converge",
      needs_attention: true,
      severity: "warning"
    )

    %{state | drift: drift}
  end

  defp configured_allowed_users do
    with {:ok, %{config: config}} when is_map(config) <- Aiur.Workflow.current(),
         users when is_list(users) <- get_in(config, ["tracker", "github", "allowed_users"]) do
      nonempty_allowed_users(users)
    else
      _ -> nil
    end
  end

  defp nonempty_allowed_users(users) do
    case MapSet.size(normalize_logins(users)) do
      0 -> nil
      _ -> users
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

  defp default_codeowners_path do
    Aiur.Codeowners.file_path() ||
      Path.join(File.cwd!(), hd(Aiur.Codeowners.standard_paths()))
  end

  defp resolve_file(path, request_fun) do
    case CodeownersFile.read(path) do
      {:ok, rules} ->
        rules |> Enum.flat_map(& &1.owners) |> Enum.uniq() |> resolve_tokens(request_fun)

      {:error, cause} ->
        {MapSet.new(), cause}
    end
  end

  defp resolve_tokens(tokens, request_fun) do
    Enum.reduce(tokens, {MapSet.new(), nil}, fn token, {logins, cause} ->
      case resolve_token(token, request_fun) do
        {:ok, members} -> {MapSet.union(logins, normalize_logins(members)), cause}
        {:error, reason} -> {logins, cause || reason}
      end
    end)
  end

  defp resolve_token("@" <> rest, request_fun) do
    case String.split(rest, "/", parts: 2) do
      [user] -> {:ok, [user]}
      [org, team] -> resolve_team(org, team, request_fun)
    end
  end

  defp resolve_token(_email, _request_fun), do: {:ok, []}

  defp resolve_team(org, team, request_fun) do
    opts = if is_function(request_fun, 1), do: [request_fun: request_fun], else: []

    case Teams.fetch_team_members(org, team, opts) do
      {:ok, logins} -> {:ok, logins}
      {:error, reason} -> {:error, {:team_lookup_failed, "@#{org}/#{team}", reason}}
    end
  end
end
