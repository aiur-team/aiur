defmodule Aiur.AgentEnvironment.Names do
  @moduledoc false

  # Credential and identity env-var names scrubbed from agent environments.

  # AIUR_RELEASE_NODE + AIUR_INSTANCE_KEY + AIUR_REPO_ROOT are the per-instance
  # identity inputs the engine exports (#431). They MUST be scrubbed too, or an agent
  # (codex inherits all env) leaks the outer instance's keyed identity into an inner
  # `aiurdev` it launches, which then reuses the outer's node/session and reaps the
  # live outer run. AIUR_REPO_ROOT is the root the key is hashed from — if it leaks the
  # inner recomputes the *outer's* key, so scrub it too (defense in depth: the dev shim
  # does not export it today, but any wrapping harness might).
  @erlang_distribution_env_names ~w(ERL_AFLAGS ERL_LIBS RELEASE_NODE RELEASE_COOKIE AIUR_RELEASE_NODE AIUR_INSTANCE_KEY AIUR_REPO_ROOT)
  @daemon_dump_env_names ~w(ERL_CRASH_DUMP ERL_CRASH_DUMP_SECONDS)
  @aiur_distribution_env_pattern ~r/\AAIUR(?:_.*)?_(?:NODE_NAME|COOKIE)\z/
  # `aiurdev` exports AIUR_RESTART_BUILD_CMD for the duration of an `aiur restart`
  # so the engine can run this checkout's rebuild between the stop and the start.
  # It is a command line bound to one checkout: inherited by an agent, an inner
  # `aiur restart` would run the OUTER checkout's builder against whatever
  # release it is pointed at. The receipt path is per-invocation for the same
  # reason — a stale one would let a later restart read a rebuild that is not its
  # own.
  @restart_build_env_names ~w(AIUR_RESTART_BUILD_CMD AIUR_RESTART_BUILD_RECEIPT AIUR_RESTART_BUILD_VERIFIES)
  @parent_log_env_names ~w(AIUR_LOGS_ROOT AIUR_AGENT_IR_LOGS_PARENT)
  @operator_only_env_names ~w(AIUR_CI_READINESS_TOKEN)
  @provider_credential_env_names ~w(DEEPSEEK_API_KEY MOONSHOT_API_KEY OPENROUTER_API_KEY OPENROUTER_MANAGEMENT_KEY)
  @provider_api_key_pattern ~r/_API_KEY(?:__[A-Z0-9_-]+)?\z/
  # The GitHub App credentials are the DAEMON's identity (#2266). Agents publish
  # as the bot account and carry its `GITHUB_TOKEN` PAT; the App installation is
  # deliberately a different login (see `AgentGitHubGuard`), and it is the
  # branch-protection bypass actor. An agent holding the App id, installation id
  # and private key can mint its own installation token, which passes through
  # neither `Aiur.GitHub.Transport` (so `Quota` never sees it) nor the `gh` guard
  # (so no `admissions` row exists) — unmetered spend against the App's GraphQL
  # pool. Scrubbed by prefix rather than by name so a credential added later
  # (`GITHUB_APP_CLIENT_SECRET`, …) is covered the day it is introduced.
  @app_credential_env_names ~w(GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY GITHUB_APP_PRIVATE_KEY_PATH)
  @app_credential_env_pattern ~r/\AGITHUB_APP_/
  # #2356: agents must not inherit the raw GitHub credential. A PAT in the agent
  # environment authenticates ANY process that speaks HTTP directly — curl,
  # Req, a Python script, a Node fetch — fully authenticated, unmetered and
  # untraced. The `gh` guard injects the credential only for the duration of a
  # governed call, from a file the daemon writes (see
  # `AgentGitHubGuard.ensure_agent_token_file/1`); the environment itself
  # carries no token. GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN are covered
  # so an enterprise deployment cannot leak its credential through the same
  # inheritance, and MISE_GITHUB_TOKEN (mise's ambient GitHub token, set by
  # operators and CI) is covered so the acceptance check
  # `env | grep -i -E 'GITHUB_TOKEN|GH_TOKEN'` returns nothing even when the
  # daemon's own environment carries it.
  @github_credential_env_names ~w(GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN MISE_GITHUB_TOKEN)

  def erlang_distribution, do: @erlang_distribution_env_names
  def daemon_dump, do: @daemon_dump_env_names
  def aiur_distribution_pattern, do: @aiur_distribution_env_pattern
  def restart_build, do: @restart_build_env_names
  def parent_log, do: @parent_log_env_names
  def operator_only, do: @operator_only_env_names
  def provider_credential, do: @provider_credential_env_names
  def provider_api_key_pattern, do: @provider_api_key_pattern
  def app_credential, do: @app_credential_env_names
  def app_credential_pattern, do: @app_credential_env_pattern
  def github_credential, do: @github_credential_env_names
end
