defmodule Aiur.RepoBase.Migration do
  @moduledoc """
  One-time migration of the legacy `Aiur.RepoBase` layout, where the
  repository node itself was the clone, into the `latest` clone plus sibling
  state tree. Runs under a cross-process lock and recovers interrupted moves.
  """

  alias Aiur.RepoBase.Clone
  alias Aiur.RepoBase.LedgerTransfer
  alias Aiur.RepoBase.StateTree
  alias Exqlite.Basic

  @legacy_built_marker ".aiur-base-built"
  @state_entries ["builds", "analytics", "meta", "executor", "experiments"]
  @migration_lease_suffix ".migration-lock.sqlite3"
  # Cache sidecar migrations copy potentially gigabytes of hex/mix/npm cache
  # under an exclusive transaction, so the busy-wait must outlast a slow copy
  # on the second of two hosts sharing one state root.
  @migration_lock_timeout_ms 300_000

  # The old layout made the repository node itself the clone. Moving a directory
  # beneath itself is impossible, so temporarily rename it beside the node,
  # recreate the node, lift state out, and finally move the clone to latest.
  # Legacy build metadata is intentionally discarded: no record means one
  # correct rebuild after migration writes the canonical node-level record.
  @doc false
  @spec migrate_legacy_layout(Path.t()) :: :ok | {:error, term()}
  def migrate_legacy_layout(base_path) do
    node = repo_node_path(base_path)

    with :ok <- StateTree.ensure_state_node_safe(node) do
      if File.dir?(Path.join(base_path, ".git")) do
        :ok
      else
        migrate_legacy_node(node, base_path)
      end
    end
  end

  defp migrate_legacy_node(node, base_path) do
    if migration_required?(node) do
      with_migration_lock(node, fn -> migrate_legacy_clone_if_needed(node, base_path) end)
    else
      :ok
    end
  end

  defp migrate_legacy_clone_if_needed(node, base_path) do
    with :ok <- recover_interrupted_migration(base_path) do
      migrate_legacy_clone_if_present(node, base_path)
    end
  end

  defp migrate_legacy_clone_if_present(node, base_path) do
    if File.dir?(Path.join(node, ".git")), do: migrate_legacy_clone(node, base_path), else: :ok
  end

  # SQLite's exclusive transaction is a cross-process lock provided by an
  # application dependency on every supported platform. The kernel releases it
  # if the holding BEAM dies, avoiding both stale files and external flock.
  defp with_migration_lock(node, migration) do
    path = migration_lease_path(node)

    case Basic.open(path) do
      {:ok, connection} ->
        with_migration_transaction(connection, path, migration)

      {:error, error} ->
        {:error, {:repo_base_migration_lock_open_failed, path, error}}
    end
  end

  defp with_migration_transaction(connection, path, migration) do
    # `after` has no implicit-function form, so the explicit resource boundary
    # is required to commit and close this cross-process lease on every exit.
    # credo:disable-for-next-line Credo.Check.Readability.PreferImplicitTry
    try do
      with :ok <- sqlite_exec(connection, "PRAGMA busy_timeout = #{@migration_lock_timeout_ms}", path),
           :ok <- sqlite_exec(connection, "BEGIN EXCLUSIVE", path) do
        migration.()
      end
    after
      _ = Basic.exec(connection, "COMMIT")
      Basic.close(connection)
    end
  end

  defp migration_required?(node) do
    File.dir?(Path.join(node, ".git")) or parked_migrations(node) != []
  end

  defp migration_lease_path(node), do: node <> @migration_lease_suffix

  defp sqlite_exec(connection, sql, path) do
    case Basic.exec(connection, sql) do
      {:ok, _query, _result, _connection} -> :ok
      {:error, error, _connection} -> {:error, {:repo_base_migration_lock_failed, path, error}}
    end
  end

  defp migrate_legacy_clone(node, base_path) do
    temporary = node <> ".migrating-" <> Clone.unique_suffix()

    with :ok <- File.rename(node, temporary),
         :ok <- finish_migration(temporary, node, base_path) do
      :ok
    else
      {:error, reason} -> {:error, {:repo_base_migration_failed, reason}}
    end
  end

  # If the process dies after parking the old node beside its destination but
  # before renaming it to `latest`, finish that move on the next touch. The
  # sidecars may already have been lifted into `node`; keeping that directory
  # intact makes recovery safe at every point in the migration sequence.
  defp recover_interrupted_migration(base_path) do
    node = repo_node_path(base_path)

    parked = parked_migrations(node)

    cond do
      File.dir?(Path.join(base_path, ".git")) ->
        :ok

      parked == [] ->
        :ok

      length(parked) == 1 ->
        [temporary] = parked

        case finish_migration(temporary, node, base_path) do
          :ok -> :ok
          {:error, reason} -> {:error, {:repo_base_migration_recovery_failed, reason}}
        end

      true ->
        {:error, :repo_base_migration_recovery_ambiguous}
    end
  end

  defp finish_migration(temporary, node, base_path) do
    findings = Path.join([node, "meta", "findings.ndjson"])
    legacy_findings = Path.join([temporary, "meta", "findings.ndjson"])
    asks = Path.join([node, "meta", "asks.ndjson"])
    legacy_asks = Path.join([temporary, "meta", "asks.ndjson"])

    with :ok <- File.mkdir_p(node),
         :ok <- move_sidecars(temporary, node),
         :ok <- LedgerTransfer.recover_ledger_transfer(findings, legacy_findings, :findings),
         :ok <- LedgerTransfer.recover_ledger_transfer(asks, legacy_asks, :asks),
         :ok <- move_state_entries(temporary, node),
         :ok <- discard_legacy_build_metadata(temporary) do
      File.rename(temporary, base_path)
    end
  end

  defp parked_migrations(node) do
    node
    |> Kernel.<>(".migrating-*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?(Path.join(&1, ".git")))
  end

  defp discard_legacy_build_metadata(path) do
    [@legacy_built_marker, Clone.base_record_name()]
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case File.rm_rf(Path.join(path, name)) do
        {:ok, _removed} -> {:cont, :ok}
        {:error, reason, _path} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  @spec import_legacy_retrospective(Path.t(), Path.t() | nil) :: :ok | {:error, term()}
  def import_legacy_retrospective(_retros_path, nil), do: :ok

  def import_legacy_retrospective(retros_path, source_root) when is_binary(source_root) do
    source = Path.join([source_root, "docs", "executor", "hourly-retrospectives.md"])

    if File.regular?(source) do
      case File.read(source) do
        {:ok, contents} -> copy_legacy_retrospective(retros_path, source, contents)
        {:error, reason} -> {:error, {:legacy_retrospective_read_failed, source, reason}}
      end
    else
      :ok
    end
  end

  defp copy_legacy_retrospective(retros_path, source, contents) do
    name = "legacy-" <> (:crypto.hash(:sha256, contents) |> Base.encode16(case: :lower) |> binary_part(0, 12)) <> ".md"
    destination = Path.join(retros_path, name)

    case File.copy(source, destination) do
      {:ok, _bytes} -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:legacy_retrospective_import_failed, source, reason}}
    end
  end

  # aiur's org transfer left exactly one known predecessor node. It is not a
  # valid state node for the current tracker and can retain the old boolean
  # marker forever, so clear it lazily when the renamed repository is touched.
  @doc false
  @spec remove_obsolete_aiur_node(String.t(), Path.t()) :: :ok | {:error, term()}
  def remove_obsolete_aiur_node(slug, base_root) do
    if slug == "aiur-team/aiur" do
      case File.rm_rf(Path.join(base_root, "its-everdred/aiur")) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> {:error, {:repo_base_orphan_cleanup_failed, reason}}
      end
    else
      :ok
    end
  end

  defp move_sidecars(from, to) do
    Enum.reduce_while(StateTree.cache_sidecars(), :ok, fn sidecar, :ok ->
      case move_sidecar(from, to, sidecar) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # State directories can already exist in the destination after an interrupted
  # migration or a concurrent initializer. Merge their contents rather than
  # leaving the legacy copy beneath `latest`; append-only ledgers retain both
  # histories, while any other file collision is preserved under a unique name.
  # A state-shaped directory with any tracked descendant belongs to the
  # application. Preserve the whole mixed directory in the clone: ignored and
  # generated application files are not safe to reclassify as Aiur state.
  defp move_state_entries(from, to) do
    Enum.reduce_while(@state_entries, :ok, fn entry, :ok ->
      source = Path.join(from, entry)
      destination = Path.join(to, entry)

      case migrate_state_entry(source, destination, from) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp migrate_state_entry(source, destination, clone_root) do
    node = Path.dirname(destination)

    with :ok <- StateTree.ensure_state_path_safe(node, destination) do
      case migration_entry_disposition(source) do
        :missing ->
          :ok

        :preserve ->
          :ok

        :migrate ->
          migrate_untracked_state_entry(source, destination, node, clone_root)

        {:error, reason} ->
          {:error, {:repo_base_migration_entry_inspection_failed, source, reason}}
      end
    end
  end

  defp migrate_untracked_state_entry(source, destination, node, clone_root) do
    case tracked_state_entry?(clone_root, source) do
      :tracked -> :ok
      :untracked -> move_state_entry(source, destination, node)
      {:error, reason} -> {:error, {:repo_base_migration_tracking_failed, source, reason}}
    end
  end

  # A legacy clone can contain untracked application links beneath a path that
  # happens to look like state. `File.dir?/1` follows those links, so migration
  # would otherwise walk and move files outside the clone. Preserve an entire
  # state-shaped entry if any boundary is a link; it remains application-owned
  # in `latest`, while the canonical state tree is recreated beside it.
  defp migration_entry_disposition(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :missing
      {:ok, %File.Stat{type: :symlink}} -> :preserve
      {:ok, %File.Stat{type: :directory}} -> migration_directory_disposition(path)
      {:ok, _stat} -> :migrate
      {:error, reason} -> {:error, reason}
    end
  end

  defp migration_directory_disposition(path) do
    with {:ok, entries} <- File.ls(path) do
      Enum.reduce_while(entries, :migrate, &reduce_migration_entry(&1, &2, path))
    end
  end

  defp reduce_migration_entry(entry, :migrate, path) do
    case migration_entry_disposition(Path.join(path, entry)) do
      :missing -> {:cont, :migrate}
      :migrate -> {:cont, :migrate}
      :preserve -> {:halt, :preserve}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp move_state_entry(source, destination, node) do
    with :ok <- StateTree.ensure_state_path_safe(node, destination) do
      case File.lstat(source) do
        {:error, :enoent} -> :ok
        {:ok, %File.Stat{type: :symlink}} -> :ok
        {:ok, %File.Stat{type: :directory}} -> merge_state_directory(source, destination, node)
        {:ok, _stat} -> move_untracked_state_file(source, destination)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp move_untracked_state_file(source, destination) do
    if File.exists?(destination),
      do: move_existing_state_file(source, destination),
      else: File.rename(source, destination)
  end

  defp move_existing_state_file(source, destination) do
    case {Path.basename(source), Path.basename(destination)} do
      {"findings.ndjson", "findings.ndjson"} -> LedgerTransfer.merge_findings(source, destination)
      {"asks.ndjson", "asks.ndjson"} -> LedgerTransfer.merge_asks(source, destination)
      _ -> File.rename(source, destination <> ".migrated-" <> Clone.unique_suffix())
    end
  end

  defp merge_state_directory(source, destination, node) do
    with :ok <- File.mkdir_p(destination),
         {:ok, entries} <- File.ls(source),
         :ok <- move_state_directory_entries(entries, source, destination, node) do
      remove_empty_directory(source)
    end
  end

  defp move_state_directory_entries(entries, source, destination, node) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case move_state_entry(Path.join(source, entry), Path.join(destination, entry), node) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp remove_empty_directory(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, :enotempty} -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp tracked_state_entry?(clone_root, path) do
    case File.lstat(path) do
      {:error, :enoent} -> :untracked
      {:ok, _stat} -> tracked_state_entry_at_path?(clone_root, path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp tracked_state_entry_at_path?(clone_root, path) do
    relative_path = Path.relative_to(path, clone_root)

    case Clone.git(["ls-files", "--", relative_path], clone_root) do
      {output, 0} when output in ["", "\n"] -> :untracked
      {_output, 0} -> :tracked
      {output, status} -> {:error, {status, output}}
    end
  end

  defp move_sidecar(from, to, sidecar) do
    source = Path.join(from, sidecar)
    destination = Path.join(to, sidecar)

    cond do
      not File.exists?(source) -> :ok
      File.exists?(destination) -> merge_sidecar(source, destination)
      true -> File.rename(source, destination)
    end
  end

  defp merge_sidecar(source, destination) do
    with {:ok, _copied} <- File.cp_r(source, destination),
         :ok <- remove_sidecar(source) do
      :ok
    else
      {:error, reason, _path} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_sidecar(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp repo_node_path(base_path), do: Path.dirname(base_path)
end
