defmodule Aiur.AgentGitHubGuard.AgentToken do
  @moduledoc """
  The credential file the agent `gh` guard reads for governed calls (#2356).
  """

  require Logger

  alias Aiur.GitHub.Budget

  @filename "agent-token"

  @doc """
  The path to the credential file. It lives in the shared budget root so the
  wrapper on every workspace resolves the same host credential without a token
  in any environment.
  """
  @spec path() :: Path.t()
  def path, do: Path.join(Budget.state_dir(), @filename)

  @doc """
  Writes the bot PAT to the guard's credential file.

  ## Contract

  The credential comes from `:token`, falling back to the daemon's own
  `GITHUB_TOKEN`/`GH_TOKEN`. `nil` and `""` mean "not supplied" and consult that
  fallback, exactly as an absent `:token` key does.

  Exactly one input removes the file: the explicit `token: :none` sentinel,
  which asserts there is deliberately no credential and never consults the
  environment. It returns `:no_credential` after deleting.

  **Failing to resolve a credential does not delete anything.** It logs a
  warning, leaves any existing file untouched, and returns `:no_credential`.
  This is deliberate and is the fix for #2478: #2356 scrubs
  `GITHUB_TOKEN`/`GH_TOKEN` from every agent environment, so "this process
  resolved nothing" is the *normal* state for anything an agent runs — including
  `mix test`, which starts the application and so reaches the boot call in
  `Aiur.start/2`. Treating that as "no credential exists" deleted the live
  credential file the whole local fleet authenticates with, once per suite run,
  silently. A process that cannot see a token has learned nothing about whether
  one exists, and must not act destructively on that absence.

  Staleness is still handled where it is genuinely knowable: a daemon that holds
  a token overwrites the file on every boot, and `remote_install_script/2`
  clears a stale token on a host it installs onto over SSH.

  Agents used to inherit the raw `GITHUB_TOKEN`/`GH_TOKEN` from the daemon
  environment; anything that spoke HTTP directly — curl, Req, a Python script,
  a Node fetch — was authenticated, unmetered and untraced (#2356). The daemon
  now keeps the credential off the agent environment entirely and writes it to
  this file instead; `Aiur.AgentEnvironment` scrubs the env vars and exports
  `AIUR_GITHUB_CREDENTIAL_FILE` so the `gh` guard can inject the credential only for
  the duration of a governed call.

  The credential written is the daemon's own inherited `GITHUB_TOKEN`/`GH_TOKEN`
  (the bot PAT agents legitimately publish as) — deliberately NOT
  `Aiur.GitHub.Config.token/0`, which under App auth resolves the daemon's
  installation token. The App installation token is the branch-protection
  bypass actor and a different budget pool; it must never reach agents.

  This is a policy boundary, not a capability boundary: agents run as the same
  OS user as the daemon, so an agent that knows the path can read the file —
  exactly as it could already read the shared budget database and the operator
  keyring. What the file removes is the raw token from the *environment* of
  every agent process, where any dependency's build script or a bare `curl`
  picks it up without even looking.
  """
  @spec ensure(keyword()) :: :ok | :no_credential | {:error, term()}
  def ensure(opts \\ []) do
    path = Keyword.get(opts, :path, path())

    case resolve_credential(opts) do
      token when is_binary(token) and token != "" ->
        with :ok <- ensure_token_parent(path, opts) do
          write_agent_token_file(path, token)
        end

      _no_credential ->
        # Deleting requires the caller to *declare* there is no credential
        # (`token: :none`). "This process could not resolve one" is not the same
        # claim, and on the daemon's own host it is usually false: #2356 scrubs
        # `GITHUB_TOKEN`/`GH_TOKEN` from every agent environment, so any boot
        # from a scrubbed shell — notably `mix test`, which starts the
        # application and reaches this call — resolved no credential and deleted
        # the live shared file the whole local fleet authenticates with. That
        # made the credential vanish seconds after each restore, with no restart
        # and no rebuild (#2478).
        #
        # The staleness property #2356 wanted is preserved where it is real: a
        # daemon that holds a token overwrites the file on every boot, an
        # explicit `:none` still cleans it, and the remote install script still
        # clears a stale token on the remote host it installs onto.
        if Keyword.get(opts, :token) == :none do
          delete_agent_token_file(path)
        else
          Logger.warning("no GitHub credential resolved; leaving the agent credential file untouched path=#{path}")

          :no_credential
        end
    end
  end

  # Resolves the credential to install, from `:token` or the daemon's own
  # environment.
  #
  # `Keyword.fetch/2` used to gate the environment fallback, so a caller that
  # passed `token: nil` got `{:ok, nil}` and skipped the fallback entirely —
  # only an *absent* key ever consulted the environment. A daemon that provably
  # held `GITHUB_TOKEN` therefore still resolved "no credential" and took the
  # destructive branch (#2478). `nil` and `""` mean "not supplied", the same as
  # an absent key; a caller that means "there is deliberately no credential"
  # says so with the explicit `:none` sentinel, which never consults the
  # environment.
  #
  # `:env_reader` exists so the fallback can be exercised deterministically.
  # Several test modules already mutate `GITHUB_TOKEN` globally under
  # `async: true`, and the regression that pins this branch must not be
  # decided by which of them happens to be running. It defaults to the real
  # process environment.
  @doc false
  @spec resolve_credential(keyword()) :: String.t() | nil
  def resolve_credential(opts) do
    case Keyword.get(opts, :token) do
      :none ->
        nil

      token when is_binary(token) and token != "" ->
        token

      _absent_or_blank ->
        read_env = Keyword.get(opts, :env_reader, &System.get_env/1)
        read_env.("GITHUB_TOKEN") || read_env.("GH_TOKEN")
    end
  end

  defp ensure_token_parent(path, opts) do
    if path == path() do
      Budget.ensure_state_dir(Keyword.drop(opts, [:path, :token, :env_reader, :remote_host]))
    else
      case File.mkdir_p(Path.dirname(path)) do
        :ok -> :ok
        {:error, reason} -> {:error, {:agent_token_dir_unavailable, Path.dirname(path), reason}}
      end
    end
  end

  defp write_agent_token_file(path, token) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(file, token),
         :ok <- IO.binwrite(file, "\n"),
         :ok <- File.close(file),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:agent_token_file_write_failed, path, reason}}
    end
  end

  defp delete_agent_token_file(path) do
    case File.rm(path) do
      :ok -> :no_credential
      {:error, :enoent} -> :no_credential
      {:error, reason} -> {:error, {:agent_token_file_unavailable, path, reason}}
    end
  end
end
