defmodule Aiur.Workspace.Materialize do
  @moduledoc "Copy-on-write workspace materialization from the warm prewarm base: cold git clone fallback, PR-anchored head checkout."

  require Logger
  alias Aiur.TicketBranch
  alias Aiur.Workspace.{Checkout, Reconstruction}

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
    materialize(workspace, fn stage ->
      with {_out, 0} <- copy_tree(base, stage),
           :ok <- Checkout.checkout_fresh_branch(stage, branch_name) do
        :ok
      else
        other -> {:error, other}
      end
    end)
  end

  def materialize_from_base(base, workspace, _branch_name, pr_head_ref)
      when is_binary(pr_head_ref) do
    materialize(workspace, fn stage ->
      with {_out, 0} <- copy_tree(base, stage),
           :ok <- Checkout.checkout_existing_pr_branch(stage, pr_head_ref) do
        :ok
      else
        other -> {:error, other}
      end
    end)
  end

  @doc false
  @spec materialize_from_base(Path.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def materialize_from_base(base, workspace, pr_head_ref) when is_binary(pr_head_ref) do
    materialize_from_base(base, workspace, TicketBranch.legacy_branch_name(Path.basename(workspace)), pr_head_ref)
  end

  defp materialize(workspace, prepare) do
    case Reconstruction.run(workspace, prepare) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("prewarm materialize failed (#{inspect(reason)}); falling back to cold clone")
        {:error, reason}
    end
  end

  # macOS APFS clones via `cp -c`; Linux btrfs/xfs reflink via `cp --reflink=auto`
  # (degrading to a full copy on ext4). Either way the warm `_build`/deps come
  # along, so the agent skips the recompile.
  defp copy_tree(base, workspace) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("cp", ["-Rc", Path.join(base, "."), workspace], stderr_to_stdout: true)
      _ -> System.cmd("cp", ["-a", "--reflink=auto", Path.join(base, "."), workspace], stderr_to_stdout: true)
    end
  end
end
