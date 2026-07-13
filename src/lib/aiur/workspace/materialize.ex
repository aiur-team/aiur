defmodule Aiur.Workspace.Materialize do
  @moduledoc "Copy-on-write workspace materialization from the warm prewarm base: cold git clone fallback, PR-anchored head checkout."

  require Logger
  alias Aiur.TicketBranch
  alias Aiur.Workspace.Checkout

  @reservation_attempts 16
  @token_bytes 16

  @doc false
  # Copy the warm base into `workspace` (CoW when the FS supports it) and branch
  # off the base's HEAD as its generated ticket branch. Public for tests;
  # callers go through `create_or_materialize/3`.
  @spec materialize_from_base(Path.t(), Path.t()) :: :ok | {:error, term()}
  def materialize_from_base(base, workspace) do
    materialize_from_base(base, workspace, TicketBranch.legacy_branch_name(Path.basename(workspace)), nil)
  end

  @doc false
  @spec materialize_from_base(Path.t(), Path.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def materialize_from_base(base, workspace, branch_name, nil) when is_binary(branch_name) do
    materialize_and_promote(base, workspace, fn staging ->
      Checkout.checkout_fresh_branch(staging, branch_name)
    end)
  end

  def materialize_from_base(base, workspace, _branch_name, pr_head_ref)
      when is_binary(pr_head_ref) do
    materialize_and_promote(base, workspace, fn staging ->
      Checkout.checkout_existing_pr_branch(staging, pr_head_ref)
    end)
  end

  @doc false
  @spec materialize_from_base(Path.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def materialize_from_base(base, workspace, pr_head_ref) when is_binary(pr_head_ref) do
    materialize_from_base(base, workspace, TicketBranch.legacy_branch_name(Path.basename(workspace)), pr_head_ref)
  end

  @doc false
  @spec recover_interrupted_replacement(Path.t()) :: :ok | {:error, term()}
  def recover_interrupted_replacement(workspace) when is_binary(workspace) do
    backups = recognized_siblings(workspace, "replaced")
    staging = recognized_siblings(workspace, "materializing")
    reservations = recognized_reservations(workspace)

    cond do
      File.exists?(workspace) ->
        cleanup_paths(backups ++ staging ++ reservations)
        :ok

      backup = newest_valid_backup(backups) ->
        case File.rename(backup, workspace) do
          :ok ->
            cleanup_paths(List.delete(backups, backup) ++ staging ++ reservations)
            :ok

          {:error, reason} ->
            {:error, {:workspace_recovery_failed, backup, reason}}
        end

      true ->
        cleanup_paths(backups ++ staging ++ reservations)
        :ok
    end
  end

  @doc false
  @spec with_reserved_sibling(Path.t(), String.t(), (-> String.t()), (Path.t() -> result)) ::
          result | {:error, term()}
        when result: term()
  def with_reserved_sibling(workspace, purpose, token_fun, operation)
      when is_binary(workspace) and is_binary(purpose) and is_function(token_fun, 0) and
             is_function(operation, 1) do
    reserve_sibling(workspace, purpose, token_fun, operation, @reservation_attempts)
  end

  defp materialize_and_promote(base, workspace, checkout) do
    File.mkdir_p!(Path.dirname(workspace))

    with :ok <- recover_interrupted_replacement(workspace) do
      with_reserved_sibling(workspace, "materializing", &random_token/0, fn staging ->
        try do
          with {_out, 0} <- copy_tree(base, staging),
               :ok <- checkout.(staging),
               :ok <- promote(staging, workspace) do
            :ok
          else
            other ->
              Logger.warning("prewarm materialize failed (#{inspect(other)}); preserving existing workspace")
              {:error, other}
          end
        after
          File.rm_rf(staging)
        end
      end)
    end
  end

  defp reserve_sibling(_workspace, purpose, _token_fun, _operation, 0) do
    {:error, {:workspace_sibling_reservation_failed, purpose, :exhausted}}
  end

  defp reserve_sibling(workspace, purpose, token_fun, operation, attempts_left) do
    sibling = sibling_path(workspace, purpose, token_fun.())
    reservation = reservation_path(sibling)

    case File.open(reservation, [:write, :exclusive]) do
      {:ok, io_device} ->
        if File.exists?(sibling) do
          File.close(io_device)
          File.rm(reservation)
          reserve_sibling(workspace, purpose, token_fun, operation, attempts_left - 1)
        else
          try do
            operation.(sibling)
          after
            File.close(io_device)
            File.rm(reservation)
          end
        end

      {:error, :eexist} ->
        reserve_sibling(workspace, purpose, token_fun, operation, attempts_left - 1)

      {:error, reason} ->
        {:error, {:workspace_sibling_reservation_failed, purpose, reason}}
    end
  end

  defp promote(staging, workspace) do
    if File.exists?(workspace) do
      replace_existing(staging, workspace)
    else
      File.rename(staging, workspace)
    end
  end

  defp replace_existing(staging, workspace) do
    with_reserved_sibling(workspace, "replaced", &random_token/0, fn backup ->
      with :ok <- File.rename(workspace, backup) do
        case File.rename(staging, workspace) do
          :ok ->
            File.rm_rf(backup)
            :ok

          {:error, reason} ->
            restore_result = File.rename(backup, workspace)
            {:error, {:workspace_promotion_failed, reason, restore_result}}
        end
      end
    end)
  end

  defp sibling_path(workspace, purpose, token),
    do: workspace <> ".#{purpose}-#{token}"

  defp reservation_path(sibling), do: sibling <> ".lock"

  defp random_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp recognized_siblings(workspace, purpose) do
    pattern = ~r/^#{Regex.escape(workspace)}\.#{purpose}-[0-9a-f]{#{@token_bytes * 2}}$/

    workspace
    |> then(&Path.wildcard(&1 <> ".#{purpose}-*"))
    |> Enum.filter(&Regex.match?(pattern, &1))
  end

  defp recognized_reservations(workspace) do
    purposes = "(?:materializing|replaced)"
    pattern = ~r/^#{Regex.escape(workspace)}\.#{purposes}-[0-9a-f]{#{@token_bytes * 2}}\.lock$/

    workspace
    |> then(&Path.wildcard(&1 <> ".*.lock"))
    |> Enum.filter(&Regex.match?(pattern, &1))
  end

  defp newest_valid_backup(backups) do
    backups
    |> Enum.filter(&valid_checkout?/1)
    |> Enum.max_by(&modified_at/1, fn -> nil end)
  end

  defp valid_checkout?(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--is-inside-work-tree"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  end

  defp modified_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat.mtime
      {:error, _reason} -> 0
    end
  end

  defp cleanup_paths(paths) do
    Enum.each(paths, &File.rm_rf/1)
  end

  # macOS APFS clones via `cp -c`; Linux btrfs/xfs reflink via `cp --reflink=auto`
  # (degrading to a full copy on ext4). Either way the warm `_build`/deps come
  # along, so the agent skips the recompile.
  defp copy_tree(base, workspace) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("cp", ["-Rc", base, workspace], stderr_to_stdout: true)
      _ -> System.cmd("cp", ["-a", "--reflink=auto", base, workspace], stderr_to_stdout: true)
    end
  end
end
