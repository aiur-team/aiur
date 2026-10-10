defmodule Aiur.AgentEnvironment.ShellScrub do
  @moduledoc false

  alias Aiur.AgentEnvironment.Names

  @neutral_zdotdir "/dev/null"

  @spec erlang_distribution_env_name?(String.t()) :: boolean()
  def erlang_distribution_env_name?(name) when is_binary(name) do
    name in Names.erlang_distribution() or Regex.match?(Names.aiur_distribution_pattern(), name)
  end

  @spec scrub_shell_command(String.t(), keyword()) :: String.t()
  def scrub_shell_command(command, opts \\ []) when is_binary(command) do
    exec_prefix = if Keyword.get(opts, :exec, false), do: "exec ", else: ""
    "#{shell_startup_prefix(opts)}; #{scrub_shell_prefix(opts)}; #{exec_prefix}#{command}"
  end

  @doc """
  Startup-file suppression for every shell that Aiur starts on an agent's
  behalf. These values are deliberately applied at the process boundary, before
  the shell gets a chance to interpret an operator-controlled startup variable.
  """
  @spec shell_startup_env() :: [{String.t(), String.t() | false}]
  def shell_startup_env, do: [{"BASH_ENV", false}, {"ENV", false}, {"ZDOTDIR", @neutral_zdotdir}]

  @spec shell_startup_env_name?(String.t() | charlist()) :: boolean()
  def shell_startup_env_name?(name) when is_binary(name),
    do: Enum.any?(shell_startup_env(), fn {startup_name, _value} -> startup_name == name end)

  def shell_startup_env_name?(name) when is_list(name),
    do: shell_startup_env_name?(List.to_string(name))

  def shell_startup_env_name?(_name), do: false

  @doc """
  Same suppression as `shell_startup_env/0`, in the shape `System.cmd/3`
  accepts. `System.cmd` spells "remove this variable" as `nil`; `Port.open`
  and tmux spell it `false`. Passing `false` to `System.cmd` raises a
  `FunctionClauseError` inside `System.validate_env/1`.
  """
  @spec system_shell_startup_env() :: [{String.t(), String.t() | nil}]
  def system_shell_startup_env do
    Enum.map(shell_startup_env(), fn
      {name, false} -> {name, nil}
      {name, value} -> {name, value}
    end)
  end

  @spec port_shell_startup_env() :: [{charlist(), charlist() | false}]
  def port_shell_startup_env do
    Enum.map(shell_startup_env(), fn
      {name, false} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  @spec shell_startup_prefix(keyword()) :: String.t()
  def shell_startup_prefix(opts \\ []) do
    unset_names = if Keyword.get(opts, :trusted_bash_env, false), do: "ENV", else: "BASH_ENV ENV"
    "unset #{unset_names}; export ZDOTDIR=#{Aiur.Shell.escape(@neutral_zdotdir)}"
  end

  @spec scrub_shell_prefix(keyword()) :: String.t()
  def scrub_shell_prefix(opts \\ []) do
    # The raw GitHub credential is scrubbed for every AGENT environment
    # (#2356). Daemon-owned operations that are not agent scopes — the prewarm
    # base build — opt out with `github_credential: false` so the operator's
    # configured build command keeps whatever auth it already had.
    github_credential_env_names =
      if Keyword.get(opts, :github_credential, true), do: Names.github_credential(), else: []

    github_credential_case =
      if github_credential_env_names == [],
        do: "",
        else: "|GITHUB_TOKEN|GH_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN|MISE_GITHUB_TOKEN"

    ("unset " <>
       Enum.join(
         Names.erlang_distribution() ++
           Names.daemon_dump() ++
           Names.restart_build() ++
           Names.parent_log() ++
           Names.operator_only() ++
           Names.provider_credential() ++
           Names.app_credential() ++
           github_credential_env_names,
         " "
       ) <>
       "; ") <>
      "for aiur_env_name in $(env | sed 's/=.*//'); do " <>
      "case \"$aiur_env_name\" in " <>
      "AIUR_NODE_NAME|AIUR_*_NODE_NAME|AIUR_COOKIE|AIUR_*_COOKIE|*_API_KEY|*_API_KEY__*|GITHUB_APP_*#{github_credential_case}) unset \"$aiur_env_name\" ;; " <>
      "esac; " <>
      "done; " <>
      release_launcher_scrub_prefix() <> "\n" <> agent_bin_scrub_prefix()
  end

  defp release_launcher_scrub_prefix do
    String.trim(~S"""
    aiur_release_root=${AIUR_RELEASE_DIR%/}
    if [ -n "$aiur_release_root" ]; then
      # ROOTDIR/BINDIR/EMU/PROGNAME are scrubbed independently, and only when
      # their value is canonical for the release. EMU/PROGNAME carry the generic
      # values `beam`/`erl` that any toolchain could set, so they are
      # release-owned only when the launcher boundary (ROOTDIR or BINDIR) is
      # actually in force; otherwise a user's unrelated EMU/PROGNAME would be
      # dropped too.
      aiur_launcher_owned=
      if [ "${ROOTDIR:-}" = "$aiur_release_root" ]; then unset ROOTDIR; aiur_launcher_owned=1; fi
      aiur_bindir=${BINDIR:-}
      aiur_bindir=${aiur_bindir%/}
      case "$aiur_bindir" in "$aiur_release_root"/erts-*/bin) unset BINDIR; aiur_launcher_owned=1 ;; esac
      unset aiur_bindir
      if [ -n "$aiur_launcher_owned" ]; then
        [ "${EMU:-}" = beam ] && unset EMU
        [ "${PROGNAME:-}" = erl ] && unset PROGNAME
      fi

      # Filter release bin/erts-*-bin PATH entries regardless of launcher-var
      # ownership. Each entry is compared with a trailing slash stripped so a
      # `.../bin/` entry cannot leak a release ERTS onto the child PATH.
      aiur_remaining_path=${PATH-}
      aiur_clean_path=
      aiur_path_separator=
      while :; do
        case "$aiur_remaining_path" in
          *:*) aiur_path_entry=${aiur_remaining_path%%:*}; aiur_remaining_path=${aiur_remaining_path#*:}; aiur_path_more=1 ;;
          *) aiur_path_entry=$aiur_remaining_path; aiur_path_more= ;;
        esac
        aiur_path_norm=${aiur_path_entry%/}
        case "$aiur_path_norm" in
          "$aiur_release_root/bin"|"$aiur_release_root"/erts-*/bin) ;;
          *) aiur_clean_path="${aiur_clean_path}${aiur_path_separator}${aiur_path_entry}"; aiur_path_separator=: ;;
        esac
        [ -n "$aiur_path_more" ] || break
      done
      PATH=$aiur_clean_path
      export PATH
    fi
    unset aiur_release_root aiur_remaining_path aiur_clean_path aiur_path_separator aiur_path_entry aiur_path_more aiur_path_norm aiur_launcher_owned
    """)
  end

  defp agent_bin_scrub_prefix do
    String.trim(~S"""
    if [ -n "${AIUR_AGENT_BIN:-}" ]; then
      PATH="$AIUR_AGENT_BIN:$PATH"
      export PATH
    fi
    if [ -n "${AIUR_BUILD_GATE_BIN:-}" ]; then
      PATH="$AIUR_BUILD_GATE_BIN:$PATH"
      export PATH
    fi
    """)
  end
end
