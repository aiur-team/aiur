defmodule Aiur.GitHub.Config.Origin do
  @moduledoc false

  require Logger

  @origin_cache_key {Aiur.GitHub.Config, :resolved_origin_repo}

  # Resolved once per VM rather than per call. `Aiur.Git.origin_repo/0` shells
  # out to git, and `configured_repo/0` runs once per issue during poll
  # normalization, so an uncached fallback would fork a process per issue on
  # exactly the shared-config installs it exists to serve. More importantly it
  # would leave `repo/0` and `configured_repo/0` reading two independent `git`
  # invocations at different instants: a transient failure of one alone yields
  # `:repository_mismatch` or `:missing_configured_repository`, turning the
  # deterministic #2518 bug into an intermittent one. Caching makes the two
  # agree by construction. Only a binary is cached, so a transient failure is
  # retried on the next call instead of frozen in for the process lifetime.
  @spec repo(keyword()) :: String.t() | nil
  def repo(opts) do
    case Keyword.get(opts, :origin_fun) do
      origin_fun when is_function(origin_fun, 0) ->
        origin_fun.()

      _default ->
        case :persistent_term.get(@origin_cache_key, :unset) do
          :unset -> resolve_origin_repo()
          resolved -> resolved
        end
    end
  end

  @doc false
  @spec resolve_origin_repo((-> String.t() | nil)) :: String.t() | nil
  def resolve_origin_repo(origin_fun \\ &Aiur.Git.origin_repo/0) do
    # `git` ran unlocked: a value cached meanwhile wins over this late result (#4071).
    with value when is_binary(value) <- origin_fun.(),
         :unset <- :persistent_term.get(@origin_cache_key, :unset) do
      # The one operator-facing surface that names which repository an unconfigured
      # install actually resolved to. Without it, a daemon launched from the wrong
      # directory auto-detects that directory's repository and reports nothing.
      Logger.info("aiur_config phase=repo_auto_detected repo=#{value} cwd=#{cwd()} reason=tracker_github_repo_unset")
      :persistent_term.put(@origin_cache_key, value)
      value
    else
      cached_or_nil -> cached_or_nil
    end
  end

  @spec cwd() :: String.t()
  def cwd do
    case File.cwd() do
      {:ok, cwd} -> cwd
      _error -> "unknown"
    end
  end
end
