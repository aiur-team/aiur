defmodule Aiur.Executor.StatePaths do
  @moduledoc """
  Durable, per-repository home for Executor recording state.

  Every Executor record used to live under `Aiur.Config.Paths.log_root_dir/0`,
  which resolves to the *current boot's* log directory. Each restart therefore
  began a fresh, empty journal, a fresh wake inbox and a missing watermark, so
  an agent arriving after a restart could never catch up on what the previous
  boot recorded — the failure mode is worst at exactly the moment an Executor
  hands over.

  These files now live beside the alert ledgers and findings in the repository
  state node (`~/.aiur/repo/<owner>/<repo>/executor`), which survives a restart.
  Legacy per-boot files are imported once, on first use, so upgrading does not
  strand the running boot's history.
  """

  alias Aiur.Config.Paths
  alias Aiur.RepoBase

  @legacy_names %{
    journal: "executor.events.ndjson",
    wakes: "executor.wakes.ndjson",
    cursor: "executor.wakes.cursor.json",
    pending: "executor.wakes.pending.json",
    subscriptions: "executor.subscriptions.json",
    watermark: "executor.listener.watermark.json"
  }

  @doc """
  Absolute directory holding durable Executor recording state.

  Resolution order: an explicit `:executor_state_dir` application override
  (tests and deliberate configuration), then the repository state node for the
  configured GitHub repository, then a repository-agnostic leaf beneath the same
  state root. Every branch survives a daemon restart; none of them is per-boot.
  """
  @spec dir() :: Path.t()
  def dir do
    case Application.get_env(:aiur, :executor_state_dir) do
      path when is_binary(path) and path != "" -> path
      _ -> resolve_dir()
    end
  end

  @doc """
  Creates the state directory and imports any legacy per-boot files.

  Idempotent and cheap: the import is skipped as soon as the destination exists,
  so repeated path lookups cost a `mkdir_p` and a handful of stats. This is the
  "records are set up automatically on first use" step — there is no operator
  provisioning command to forget.
  """
  @spec ensure() :: :ok
  def ensure do
    root = dir()

    with :ok <- File.mkdir_p(root) do
      Enum.each(Map.keys(@legacy_names), &import_legacy(&1, root))
    end

    :ok
  rescue
    _error -> :ok
  end

  @spec journal_path() :: Path.t()
  def journal_path, do: path_for(:journal)

  @spec subscriptions_path() :: Path.t()
  def subscriptions_path, do: path_for(:subscriptions)

  @spec wakes_path() :: Path.t()
  def wakes_path, do: path_for(:wakes)

  @spec cursor_path() :: Path.t()
  def cursor_path, do: path_for(:cursor)

  @spec pending_path() :: Path.t()
  def pending_path, do: path_for(:pending)

  @spec watermark_path() :: Path.t()
  def watermark_path, do: path_for(:watermark)

  @doc "Durable store of consumer lease claims and their liveness evidence."
  @spec claims_path() :: Path.t()
  def claims_path, do: Path.join(dir(), "#{Paths.repo_name()}.executor.claims.json")

  @spec path_for(atom()) :: Path.t()
  def path_for(key) when is_map_key(@legacy_names, key) do
    ensure()
    Path.join(dir(), "#{Paths.repo_name()}.#{Map.fetch!(@legacy_names, key)}")
  end

  @doc false
  @spec legacy_path(atom()) :: Path.t()
  def legacy_path(key) when is_map_key(@legacy_names, key),
    do: Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.#{Map.fetch!(@legacy_names, key)}")

  defp resolve_dir do
    case repo_slug() do
      slug when is_binary(slug) and slug != "" -> RepoBase.executor_path("https://github.com/#{slug}.git")
      _ -> Path.join([RepoBase.state_root(), "_unresolved", Paths.project_name(), "executor"])
    end
  end

  defp repo_slug do
    Aiur.GitHub.Config.repo()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  # A one-time copy, never a move: the boot directory stays readable for
  # forensics, and a second import is skipped because the destination exists.
  defp import_legacy(key, root) do
    destination = Path.join(root, "#{Paths.repo_name()}.#{Map.fetch!(@legacy_names, key)}")
    source = legacy_path(key)

    if source != destination and not File.exists?(destination) and File.regular?(source) do
      _ = File.cp(source, destination)
    end

    :ok
  rescue
    _error -> :ok
  end
end
