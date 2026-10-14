defmodule Aiur.AgentGitHubGuard.RemoteInstall do
  @moduledoc """
  Builds the install script an SSH worker runs to receive the agent guards.
  """

  alias Aiur.{AgentCommandInstaller, AgentGitHubGuard}
  alias Aiur.AgentGitHubGuard.AgentToken

  @doc "The shell script that installs `scripts` and the agent support directories into `workspace`."
  @spec script(Path.t(), Path.t(), [{String.t(), String.t()}], keyword()) :: String.t()
  def script(workspace, relative_bin_dir, scripts, opts) when is_binary(workspace) do
    scripts =
      Enum.map_join(scripts, "\n", fn {name, script} ->
        AgentCommandInstaller.remote_install_script(workspace, relative_bin_dir, [name], script)
      end)

    # Remote workers get the same empty agent-private `GH_CONFIG_DIR`; without
    # it an SSH-launched agent still reaches the remote host's `~/.config/gh`.
    # The symlink refusal mirrors `ensure_gh_config_dir/1` — `mkdir -p` alone
    # would succeed against an agent-planted symlink to the operator's config —
    # and the launch fails loudly rather than exporting a variable that points
    # somewhere the agent controls.
    config_dir = Aiur.Shell.escape(AgentGitHubGuard.gh_config_dir(workspace))
    quota_dir = Aiur.Shell.escape(AgentGitHubGuard.quota_dir(workspace))
    token_file = remote_agent_token_script(opts)

    scripts <>
      "\nif [ -L #{config_dir} ] || { [ -e #{config_dir} ] && [ ! -d #{config_dir} ]; }; then\n" <>
      "  echo 'unsafe agent gh config dir' >&2\n  exit 73\nfi\n" <>
      "mkdir -p #{config_dir} || { echo 'agent gh config dir is unavailable' >&2; exit 73; }\n" <>
      "if [ -L #{quota_dir} ] || { [ -e #{quota_dir} ] && [ ! -d #{quota_dir} ]; }; then\n" <>
      "  echo 'unsafe agent quota dir' >&2\n  exit 73\nfi\n" <>
      "mkdir -p #{quota_dir} || { echo 'agent quota dir is unavailable' >&2; exit 73; }\n" <>
      token_file
  end

  # Remote workers get the same #2356 credential file the local `gh` guard
  # reads (`~/.aiur/github-budget/agent-token`), written from the daemon's own
  # inherited bot PAT. The token travels inside the install script the daemon
  # already ships over SSH — the same trust boundary as the guard payload
  # itself — and is deleted when no credential is available so a stale install
  # cannot leave a dead token authenticating the next agent.
  #
  # That deletion is scoped to a genuinely remote install (#2478). `$HOME` in
  # this script is somebody else's home only when the script really runs over
  # SSH; the string is generated in-process and is executed against the
  # *operator's own* `$HOME` by anything that runs it locally — the installer
  # tests do exactly that, four times per suite run. Because #2356 scrubs
  # `GITHUB_TOKEN`/`GH_TOKEN` from every agent environment, an agent running the
  # suite resolves no credential, so each run emitted
  # `rm -f "$HOME/.aiur/github-budget/agent-token"` and destroyed the single
  # shared credential every local agent authenticates with — while the tests
  # stayed green.
  #
  # Scoping beats namespacing here: the path must stay exactly where the remote
  # `gh` guard looks for it, so it cannot be made per-worker without changing
  # the lookup on both sides. The cleanup is meaningful only for an install that
  # really lands on another host, and only the remote provisioning path knows
  # that. Making it opt-in via `:remote_host` leaves the destructive branch
  # unreachable from every caller that generates or executes this script
  # locally, while preserving the stale-install property where it applies.
  defp remote_agent_token_script(opts) do
    case AgentToken.resolve_credential(opts) do
      token when is_binary(token) and token != "" ->
        token = Aiur.Shell.escape(token)

        [
          "mkdir -p \"$HOME/.aiur/github-budget\"",
          "printf '%s\\n' #{token} > \"$HOME/.aiur/github-budget/agent-token\"",
          "chmod 600 \"$HOME/.aiur/github-budget/agent-token\""
        ]
        |> Enum.join("\n")

      _no_credential ->
        if remote_install?(opts) do
          "rm -f \"$HOME/.aiur/github-budget/agent-token\" 2>/dev/null || true\n"
        else
          "# no GitHub credential available; leaving the host credential file untouched\n"
        end
    end
  end

  defp remote_install?(opts) do
    case Keyword.get(opts, :remote_host) do
      host when is_binary(host) and host != "" -> true
      _local_or_unknown -> false
    end
  end
end
