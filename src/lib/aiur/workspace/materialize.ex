defmodule Aiur.Workspace.Materialize do
  @moduledoc "Copy-on-write workspace materialization from the warm prewarm base: cold git clone fallback, PR-anchored head checkout."

  require Logger
  alias Aiur.Workspace.Checkout

  @doc false
  # Copy the warm base into `workspace` (CoW when the FS supports it) and branch
  # off the base's HEAD as `aiur/<id>`. Public for tests; callers go through
  # `create_or_materialize/1`.
  @spec materialize_from_base(Path.t(), Path.t()) :: :ok | {:error, term()}
  def materialize_from_base(base, workspace) do
    File.rm_rf!(workspace)
    # The repo-namespaced layout (`<root>/<repo>/<issue>`) means the `<repo>`
    # parent dir may not exist yet for the first agent of a repo; `cp` needs it
    # present. The cold `create_workspace/1` path gets this via `mkdir_p!`; the
    # materialize path must create the parent itself (the leaf is made by `cp`).
    File.mkdir_p!(Path.dirname(workspace))

    with {_out, 0} <- copy_tree(base, workspace),
         :ok <- Checkout.checkout_fresh_branch(workspace) do
      :ok
    else
      other ->
        Logger.warning("prewarm materialize failed (#{inspect(other)}); falling back to cold clone")
        File.rm_rf!(workspace)
        {:error, other}
    end
  end

  @doc false
  # PR-anchored materialize: copy the warm base (CoW) then check out the PR's
  # existing head branch (`pr_head_ref`) instead of creating `aiur/<id>`. The PR
  # branch is a human's existing branch — the agent works it directly and pushes
  # back there, never opening a new `aiur/<id>` PR. Public for tests; callers go
  # through `create_or_materialize/2`.
  @spec materialize_from_base(Path.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def materialize_from_base(base, workspace, pr_head_ref) when is_binary(pr_head_ref) do
    File.rm_rf!(workspace)
    File.mkdir_p!(Path.dirname(workspace))

    with {_out, 0} <- copy_tree(base, workspace),
         :ok <- Checkout.checkout_existing_pr_branch(workspace, pr_head_ref) do
      :ok
    else
      other ->
        Logger.warning("prewarm materialize (PR-anchored) failed (#{inspect(other)}); falling back to cold clone")
        File.rm_rf!(workspace)
        {:error, other}
    end
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
