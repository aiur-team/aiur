defmodule Aiur.Workspace.Materialize do
  @moduledoc "Copy-on-write workspace materialization from the warm prewarm base: cold git clone fallback, PR-anchored head checkout."

  require Logger
  alias Aiur.TicketBranch
  alias Aiur.Workspace.Checkout

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

  defp materialize_and_promote(base, workspace, checkout) do
    File.mkdir_p!(Path.dirname(workspace))
    staging = sibling_path(workspace, "materializing")

    try do
      with {_out, 0} <- copy_tree(base, staging),
           :ok <- checkout.(staging),
           :ok <- promote(staging, workspace) do
        :ok
      else
        other ->
          Logger.warning("prewarm materialize failed (#{inspect(other)}); falling back to cold clone")
          {:error, other}
      end
    after
      File.rm_rf(staging)
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
    backup = sibling_path(workspace, "replaced")

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
  end

  defp sibling_path(workspace, purpose) do
    unique = System.unique_integer([:positive, :monotonic])
    workspace <> ".#{purpose}-#{unique}"
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
