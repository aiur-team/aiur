defmodule Aiur.RepoBase.Clone do
  @moduledoc """
  Clone, fetch/reset and base-build steps for `Aiur.RepoBase`, with the git
  auth environment and the node-level base record that marks a valid build.
  """

  alias Aiur.AgentEnvironment
  alias Aiur.AgentPubSub
  alias Aiur.Config
  alias Aiur.RepoBase.StateTree

  @base_record "base-record.json"

  @doc false
  @spec base_record_name() :: String.t()
  def base_record_name, do: @base_record

  @spec clone_url() :: String.t() | nil
  def clone_url do
    {module, function, args} = Application.get_env(:aiur, :repo_base_clone_url, {Aiur.Tracker, :clone_url, []})
    apply(module, function, args)
  end

  @doc false
  @spec ensure_clone(Path.t(), String.t()) :: :ok | {:error, term()}
  def ensure_clone(base_path, repo_url), do: ensure_clone(base_path, repo_url, &ignore_process_event/4)

  @doc false
  @spec ensure_clone(Path.t(), String.t(), (atom(), pos_integer(), pos_integer() | nil, term() -> term())) ::
          :ok | {:error, term()}
  def ensure_clone(base_path, repo_url, on_process) do
    if File.dir?(Path.join(base_path, ".git")) do
      :ok
    else
      emit(:cloning)
      File.rm_rf!(base_path)
      File.mkdir_p!(Path.dirname(base_path))

      case git(["clone", "--branch", Config.base_branch(), repo_url, base_path], nil, on_process) do
        {_out, 0} -> :ok
        {out, status} -> {:error, {:repo_base_clone_failed, status, out}}
      end
    end
  end

  @doc false
  @spec fetch_and_reset(Path.t()) :: {:ok, boolean()} | {:error, term()}
  def fetch_and_reset(base_path), do: fetch_and_reset(base_path, &ignore_process_event/4)

  @doc false
  @spec fetch_and_reset(Path.t(), (atom(), pos_integer(), pos_integer() | nil, term() -> term())) ::
          {:ok, boolean()} | {:error, term()}
  def fetch_and_reset(base_path, on_process) do
    emit(:fetching)
    branch = Config.base_branch()

    with {_fetch, 0} <- git(["fetch", "origin", branch, "--quiet"], base_path, on_process),
         {local, 0} <- git(["rev-parse", "HEAD"], base_path, on_process),
         {remote, 0} <- git(["rev-parse", "origin/#{branch}"], base_path, on_process) do
      reset_if_changed(base_path, String.trim(local) == String.trim(remote), on_process)
    else
      {out, status} -> {:error, {:repo_base_fetch_failed, status, out}}
    end
  end

  defp reset_if_changed(_base_path, true, _on_process), do: {:ok, false}

  defp reset_if_changed(base_path, false, on_process) do
    case git(["reset", "--hard", "origin/#{Config.base_branch()}"], base_path, on_process) do
      {_out, 0} -> {:ok, true}
      {out, status} -> {:error, {:repo_base_reset_failed, status, out}}
    end
  end

  @doc false
  @spec maybe_build(Path.t(), String.t() | nil, boolean()) :: {:ok, Path.t()} | {:error, term()}
  def maybe_build(base_path, base_build, rebuild?), do: maybe_build(base_path, base_build, rebuild?, &ignore_process_event/4)

  @doc false
  @spec maybe_build(Path.t(), String.t() | nil, boolean(), (atom(), pos_integer(), pos_integer() | nil, term() -> term())) ::
          {:ok, Path.t()} | {:error, term()}
  def maybe_build(base_path, _base_build, false, _on_process), do: {:ok, base_path}

  def maybe_build(base_path, base_build, true, on_process) do
    emit(:building)

    case run_base_build(base_path, base_build, on_process) do
      :ok ->
        case write_base_record(base_path, base_build) do
          :ok -> {:ok, base_path}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_base_build(_base_path, nil, _on_process), do: :ok
  defp run_base_build(_base_path, "", _on_process), do: :ok

  defp run_base_build(base_path, command, on_process) do
    # Same execution shape as workspace hooks: scrub the Executor’s Erlang
    # distribution env at the shell level, then run in the base dir. `base_env/1`
    # trusts the base's mise.toml (MISE_TRUSTED_CONFIG_PATHS) so mise-provided
    # tools run. Cache homes point at the daemon-owned executor subtree, outside
    # both `latest` and the agent-writable sidecars, so materialized workspaces
    # inherit only the repository tree and prewarm never executes agent-controlled
    # package cache content.
    scrubbed = AgentEnvironment.scrub_shell_command(command, github_credential: false)

    {out, status} =
      run_command("sh", ["-c", scrubbed], base_path, base_env(base_path) ++ AgentEnvironment.port_shell_startup_env(), on_process)

    case status do
      0 -> :ok
      _ -> {:error, {:base_build_failed, status, out}}
    end
  end

  defp collect_port_output(port, chunks) do
    receive do
      {^port, {:data, chunk}} -> collect_port_output(port, [chunk | chunks])
      {^port, {:exit_status, status}} -> {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    end
  end

  defp run_command(executable, args, cwd, env, on_process) do
    path = System.find_executable(executable)
    port = Port.open({:spawn_executable, String.to_charlist(path)}, port_options(args, cwd, env))

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        identity =
          case Aiur.ProcessTree.process_identity(os_pid) do
            {:ok, value} -> {:known, value}
            other -> other
          end

        on_process.(:started, os_pid, nil, identity)
        process_group = Aiur.ProcessTree.process_group_for_pid(os_pid)
        identity = Aiur.ProcessTree.refresh_identity(os_pid, identity)
        on_process.(:group, os_pid, process_group, identity)
        {out, status} = collect_port_output(port, [])
        on_process.(:finished, os_pid, process_group, identity)
        {out, status}

      _ ->
        collect_port_output(port, [])
    end
  end

  defp port_options(args, cwd, env) do
    [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(args, &String.to_charlist/1), env: port_env(env)]
    |> maybe_put_cwd(cwd)
  end

  defp maybe_put_cwd(options, nil), do: options
  defp maybe_put_cwd(options, cwd), do: Keyword.put(options, :cd, String.to_charlist(cwd))

  defp port_env(overrides) do
    Enum.map(overrides, fn
      {name, value} when is_nil(value) or value == false -> {port_charlist(name), false}
      {name, value} -> {port_charlist(name), port_charlist(value)}
    end)
  end

  defp port_charlist(value) when is_binary(value), do: String.to_charlist(value)
  defp port_charlist(value) when is_list(value), do: value

  @doc false
  @spec git([String.t()], Path.t() | nil) :: {String.t(), non_neg_integer()}
  def git(args, cwd), do: git(args, cwd, &ignore_process_event/4)

  @doc false
  @spec git([String.t()], Path.t() | nil, (atom(), pos_integer(), pos_integer() | nil, term() -> term())) ::
          {String.t(), non_neg_integer()}
  def git(args, cwd, on_process) do
    args = if cwd, do: ["-C", cwd | args], else: args
    run_command("git", args, nil, git_auth_env(), on_process)
  end

  defp ignore_process_event(_event, _os_pid, _process_group, _identity), do: :ok

  # Auth for networked git calls. Git never reads GITHUB_TOKEN on its own, so a
  # warm-base clone/fetch of a private repo 401s ("Password authentication is not
  # supported") — and with no TTY it then hangs/fails trying to prompt for a
  # username. We inject the token as a per-host HTTP Authorization header via
  # git's env-based config (GIT_CONFIG_*), matching what GitHub Actions does:
  #
  #   - env config (not `-c key=value`) keeps the token out of argv / `ps`
  #   - a clean origin URL keeps it out of the cloned `.git/config`
  #   - scoping to `http.https://github.com/.` confines it to github.com
  #
  # `GIT_TERMINAL_PROMPT=0` makes git fail fast instead of blocking on a
  # credential prompt (the "could not read Username … Device not configured"
  # case) when no token is available. The header is HTTP-transport only, so it is
  # inert for the local rev-parse/reset calls that also route through `git/2`.
  @spec git_auth_env() :: [{String.t(), String.t()}]
  def git_auth_env do
    {module, function, args} = Application.get_env(:aiur, :repo_base_git_token, {Aiur.Workspace.NoToken, :token, []})
    git_auth_env(apply(module, function, args))
  end

  @doc false
  @spec git_auth_env(String.t() | nil) :: [{String.t(), String.t()}]
  def git_auth_env(token) when is_binary(token) and token != "" do
    header = "AUTHORIZATION: basic " <> Base.encode64("x-access-token:" <> token)

    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"},
      {"GIT_CONFIG_VALUE_0", header}
    ]
  end

  def git_auth_env(_token), do: [{"GIT_TERMINAL_PROMPT", "0"}]

  @doc false
  @spec head_of(Path.t()) :: String.t() | nil
  def head_of(base_path) do
    case git(["rev-parse", "HEAD"], base_path) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  @doc false
  @spec remote_head(String.t()) :: {:ok, String.t()} | {:error, term()}
  def remote_head(repo_url) do
    case git(["ls-remote", repo_url, "refs/heads/#{Config.base_branch()}"], nil) do
      {out, 0} ->
        case out |> String.split() |> List.first() do
          head when is_binary(head) and head != "" -> {:ok, head}
          _ -> {:error, :empty_remote_head}
        end

      {out, status} ->
        {:error, {:ls_remote_failed, status, out}}
    end
  end

  # A boolean marker made a moved clone indistinguishable from a freshly built
  # one. Keep the record beside `latest`, where it cannot leak into a copied
  # workspace, and require both inputs that define a valid build to match.
  @doc false
  @spec built?(Path.t(), String.t() | nil) :: boolean()
  def built?(base_path, base_build) do
    with {:ok, record_body} <- File.read(base_record_path(base_path)),
         {:ok, record} <- Jason.decode(record_body),
         clone_head when is_binary(clone_head) <- Map.get(record, "clone_head"),
         script_hash when is_binary(script_hash) <- Map.get(record, "prewarm_script_hash"),
         true <- clone_head == head_of(base_path),
         true <- script_hash == prewarm_script_hash(base_build) do
      true
    else
      _ -> false
    end
  end

  defp write_base_record(base_path, base_build) do
    with head when is_binary(head) <- head_of(base_path),
         :ok <- File.mkdir_p(repo_node_path(base_path)),
         {:ok, body} <-
           Jason.encode(%{
             "clone_head" => head,
             "prewarm_script_hash" => prewarm_script_hash(base_build),
             "built_at" => DateTime.utc_now() |> DateTime.to_iso8601()
           }) do
      target = base_record_path(base_path)
      temporary = target <> ".tmp-" <> unique_suffix()

      with :ok <- File.write(temporary, body),
           :ok <- File.rename(temporary, target) do
        :ok
      else
        {:error, reason} ->
          File.rm(temporary)
          {:error, {:repo_base_record_write_failed, reason}}
      end
    else
      _ -> {:error, :repo_base_head_unavailable}
    end
  end

  defp prewarm_script_hash(base_build) when is_binary(base_build),
    do: :crypto.hash(:sha256, base_build) |> Base.encode16(case: :lower)

  defp prewarm_script_hash(_base_build), do: :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

  defp repo_node_path(base_path), do: Path.dirname(base_path)
  defp base_record_path(base_path), do: Path.join(repo_node_path(base_path), @base_record)

  @doc false
  @spec unique_suffix() :: String.t()
  def unique_suffix do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
  end

  defp base_env(base_path) do
    cache_root = Path.join([repo_node_path(base_path), "executor", "package-manager-cache"])
    [hex_home, mix_home, npm_cache] = StateTree.cache_sidecar_paths(cache_root)

    AgentEnvironment.base_env(base_path) ++
      [
        {"HEX_HOME", hex_home},
        {"MIX_HOME", mix_home},
        {"npm_config_cache", npm_cache}
      ]
  end

  defp emit(phase), do: AgentPubSub.broadcast_prewarm_phase(phase)
end
