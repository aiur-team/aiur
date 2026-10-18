defmodule Aiur.AgentRunner.SessionOptions do
  @moduledoc false
  require Logger
  alias Aiur.Accounts
  alias Aiur.Accounts.UsageReadings
  alias Aiur.AgentRunner.SessionResume
  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.HeadroomDispatch
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Tracker
  @type worker_host :: String.t() | nil

  @doc false
  @spec resolve_session_options(Issue.t(), keyword(), worker_host()) ::
          {String.t(), boolean(), keyword()}
  def resolve_session_options(issue, opts, worker_host) do
    backend = CodingAgent.backend_for(issue)
    effort = CodingAgent.effort_for(issue)

    rc? =
      (CodingAgent.remote_control_forced?(issue) or CodingAgent.routing_remote?(issue) or
         Config.agent_remote_control?()) and CodingAgent.remote_control?(backend)

    session_backend = remote_session_backend(backend, rc?)

    # Resolved against the transport that actually receives the string, so a
    # generic tag (`codex:sol`) becomes the newest version in that family
    # while an explicitly pinned one stays pinned. An unrecognized model is
    # passed through unchanged and surfaced in `run_session/5` rather than
    # swapped for something else.
    model = CodingAgent.resolve_model(session_backend, CodingAgent.model_for(issue))

    # Rejoin the prior agent thread across an aiur restart instead of cold-
    # starting a fresh conversation that re-discovers the work (issue #378).
    # Only a resumable, local backend with a persisted handle qualifies; any miss degrades silently to a clean start.
    resume_thread_id = Keyword.get(opts, :resume_thread_id) || SessionResume.load_resume_thread_id(session_backend, worker_host, issue.identifier)

    session_opts =
      [
        backend: session_backend,
        model: model,
        effort: effort,
        worker_host: worker_host,
        remote_control: rc?,
        identifier: issue.identifier,
        attempt_id: Keyword.get(opts, :telemetry_attempt_id)
      ]
      |> maybe_put_rc_name(rc?, issue)
      |> maybe_put_account(session_backend, config_for_accounts(opts), HeadroomDispatch.account_opts(issue, session_backend, opts))
      |> HeadroomDispatch.put_selection_reason(issue)
      |> SessionResume.maybe_put_resume_thread_id(resume_thread_id)

    {session_backend, rc?, session_opts}
  end

  defp config_for_accounts(opts), do: Keyword.get_lazy(opts, :account_config, fn -> Config.settings!().agent end)

  defp maybe_put_account(session_opts, backend, config, opts) do
    account_backend = if backend == "claude-repl", do: "claude", else: backend

    case Keyword.get(opts, :account_name) do
      name when is_binary(name) and account_backend in ["claude", "codex"] ->
        Keyword.merge(session_opts, account_name: name, env: Accounts.profile_env(account_backend, name))

      _ ->
        case Accounts.capability(account_backend) do
          {:ok, %{multi: :available, supported: true}} ->
            attach_selected_account(session_opts, account_backend, config, opts)

          _ ->
            session_opts
        end
    end
  end

  defp attach_selected_account(session_opts, backend, config, opts) do
    candidates = configured_account_candidates(config, backend, opts)

    if candidates == [] do
      session_opts
    else
      {usages, reset_at} = account_usages(backend, candidates, opts)
      choose_account(session_opts, backend, candidates, config, usages, reset_at)
    end
  end

  defp configured_account_candidates(config, backend, opts) do
    names = Map.get(config, :accounts) || %{}
    names = Map.get(names, backend, [])
    list_accounts = Keyword.get(opts, :account_list_fun, &Accounts.list/1)
    registered = MapSet.new(list_accounts.(backend), & &1.name)
    Enum.filter(names, &MapSet.member?(registered, &1))
  end

  defp account_usages("claude", candidates, opts) do
    polled = UsageReadings.snapshot("claude", candidates)
    fetch_usage = Keyword.get(opts, :account_usage_fetcher, &account_usage/1)

    readings = Map.new(candidates, &{&1, account_usage_reading(&1, polled, fetch_usage)})
    usages = Map.new(readings, fn {name, {usage, _reset_at}} -> {name, usage} end)

    reset_at =
      readings
      |> Enum.flat_map(fn {_name, {usage, reset}} -> if account_at_limit?(usage), do: [reset], else: [] end)
      |> earliest_reset()

    {usages, reset_at}
  end

  defp account_usages(_backend, candidates, _opts), do: {Map.new(candidates, &{&1, nil}), nil}

  defp account_usage_reading(name, polled, fetch_usage) do
    case Map.fetch(polled, name) do
      {:ok, %{reading: %{windows: windows}}} -> {usage_map(windows), limited_window_reset(windows)}
      {:ok, _unavailable} -> {nil, nil}
      :error -> normalize_account_usage(fetch_usage.(name))
    end
  end

  defp normalize_account_usage({:ok, %{windows: windows}, _metadata}), do: {usage_map(windows), limited_window_reset(windows)}
  defp normalize_account_usage(%{windows: windows}), do: {usage_map(windows), limited_window_reset(windows)}
  defp normalize_account_usage(usage) when is_map(usage), do: {usage, nil}
  defp normalize_account_usage(_usage), do: {nil, nil}

  defp choose_account(session_opts, backend, candidates, config, usages, reset_at) do
    mode = config.account_selection || "balance"

    case Accounts.select(backend, candidates, mode, usages) do
      {:ok, name} ->
        session_opts
        |> put_selected_account(backend, name, usages)

      {:error, reason} ->
        put_account_selection_error(session_opts, backend, reason, reset_at)
    end
  end

  defp put_selected_account(session_opts, backend, name, usages) do
    reason = account_selection_reason(usages[name])

    Keyword.merge(session_opts,
      account_name: name,
      account_selection_reason: reason,
      env: selected_account_env(backend, name)
    )
  end

  defp account_selection_reason(%{"seven_day" => weekly_usage}) when is_number(weekly_usage), do: nil
  defp account_selection_reason(_usage), do: "usage unavailable"

  defp selected_account_env("claude-repl", name), do: Accounts.profile_env("claude", name)
  defp selected_account_env(backend, name) when backend in ["claude", "codex"], do: Accounts.profile_env(backend, name)
  defp selected_account_env(_backend, _name), do: []

  defp put_account_selection_error(session_opts, "claude", :no_available_account, %DateTime{} = reset_at),
    do: Keyword.put(session_opts, :account_selection_wait, DateTime.to_iso8601(reset_at))

  defp put_account_selection_error(session_opts, _backend, reason, _reset_at),
    do: Keyword.put(session_opts, :account_selection_error, reason)

  defp account_usage(name) do
    case Accounts.usage("claude", name) do
      {:ok, %{windows: _windows}, _metadata} = result ->
        result

      _unavailable ->
        nil
    end
  end

  defp usage_map(windows), do: Map.new(windows, fn window -> {window.window, window.used_percent} end)

  defp account_at_limit?(usage) when is_map(usage),
    do: Enum.any?(["seven_day", "five_hour"], &(is_number(usage[&1]) and usage[&1] >= 100))

  defp account_at_limit?(_usage), do: false

  defp limited_window_reset(windows) do
    windows
    |> Enum.filter(&(is_number(&1.used_percent) and &1.used_percent >= 100))
    |> Enum.map(&Map.get(&1, :resets_at))
    |> earliest_reset()
  end

  defp earliest_reset(resets) do
    resets
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.min_by(&DateTime.to_unix/1, fn -> nil end)
  end

  # Mirror the full claude transcript into the opencode pane for an RC claude-repl
  # agent, so the pane and Remote Control channel are two views of one conversation.
  # Headless/codex/RC-off sessions stream their own rich transcript and are left
  # The `--remote-control <name>` string is what the Executor sees as the
  # chat title in the Claude app / mobile, so derive it from the issue
  # ("Aiur: Actions #99 - Title") rather than the opaque `aiur-repl-<pid>-<n>`
  # window name. Only set when RC is active; headless and RC-off REPL sessions
  # keep the default name.
  defp maybe_put_rc_name(opts, true, issue), do: Keyword.put(opts, :rc_name, rc_session_name(issue))
  defp maybe_put_rc_name(opts, false, _issue), do: opts
  # Remote control physically rides the persistent-REPL transport, so an
  # RC-on dispatch is promoted to its registry-declared `remote_transport`
  # (`Aiur.CodingAgent.remote_transport/1`, carrying the resolved model).
  # Backends without the capability — and every RC-off dispatch — run as
  # resolved.
  @doc false
  @spec remote_session_backend(String.t(), boolean()) :: String.t()
  def remote_session_backend(backend, true), do: CodingAgent.remote_transport(backend)
  def remote_session_backend(backend, _rc?), do: backend
  # Seed the workspace trust flag before an RC REPL spawns. RC refuses to
  # start in an untrusted directory; without this the REPL sticks on the
  # trust dialog and silently degrades to the headless backend. Only the
  # local path is trusted — RC is local-only (a remote worker_host's
  # workspace lives on another machine), matching `promote_to_remote`'s
  # guard. A trust failure is logged but not fatal: the degrade path still
  # lands a working headless agent rather than stranding the issue.
  @doc false
  @spec maybe_trust_remote_control_workspace(Path.t(), boolean(), worker_host(), fun()) :: :ok
  def maybe_trust_remote_control_workspace(workspace, rc?, worker_host, trust_fun)

  def maybe_trust_remote_control_workspace(workspace, true, nil, trust_fun)
      when is_binary(workspace) and is_function(trust_fun, 1) do
    case trust_fun.(workspace) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("remote-control workspace trust failed; RC may degrade to headless: workspace=#{workspace} reason=#{inspect(reason)}")
        :ok
    end
  end

  def maybe_trust_remote_control_workspace(_workspace, _rc?, _worker_host, _trust_fun), do: :ok
  # Executor-facing RC chat title: `Aiur: <Repo> #<ID> - <title>`, e.g.
  # `Aiur: Actions #7 - CLI: ENS namespace`. The repo name is the capitalized
  # short name of the configured tracker repo (`its-applekid/actions` ->
  # `Actions`); when the tracker exposes no repo it is omitted, leaving
  # `Aiur: #<ID> - <title>`. `repo` is injectable for tests.
  @doc false
  @spec rc_session_name(Issue.t(), String.t() | nil) :: String.t()
  def rc_session_name(issue, repo \\ Tracker.project_identity()) do
    label = issue.identifier || issue.id
    title = issue.title || ""

    "#{rc_session_prefix(repo)} ##{label} - #{title}"
    |> String.replace(~r/[[:cntrl:]'"`]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 60)
  end

  defp rc_session_prefix(repo) do
    case repo_short_name(repo) do
      nil -> "Aiur:"
      name -> "Aiur: #{name}"
    end
  end

  # Capitalized short name of an `owner/name` repo string; nil when absent or empty.
  # Only the first character is upcased so existing casing (e.g. `myRepo`) survives.
  defp repo_short_name(repo) when is_binary(repo) do
    case repo |> String.split("/") |> List.last() |> String.trim() do
      "" -> nil
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
    end
  end

  defp repo_short_name(_repo), do: nil
end
