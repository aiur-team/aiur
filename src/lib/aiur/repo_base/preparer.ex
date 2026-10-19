defmodule Aiur.RepoBase.Preparer do
  @moduledoc false

  alias Aiur.Config.Paths
  alias Aiur.RepoBase.Clone
  alias Aiur.RepoBase.Migration
  alias Aiur.RepoBase.StateTree

  @doc false
  @spec prepare(Path.t(), String.t()) :: :ok | {:ok, boolean()} | {:error, term()}
  def prepare(base_path, repo_url), do: prepare(base_path, repo_url, fn _event, _pid, _group, _identity -> :ok end)

  @doc false
  @spec prepare(Path.t(), String.t(), (atom(), pos_integer(), pos_integer() | nil, term() -> term())) ::
          :ok | {:ok, boolean()} | {:error, term()}
  def prepare(base_path, repo_url, on_process) do
    with :ok <- Migration.remove_obsolete_aiur_node(Paths.repo_slug(repo_url), Paths.repo_state_root()),
         :ok <- Migration.migrate_legacy_layout(base_path),
         :ok <- StateTree.ensure_state_tree_at(Path.dirname(base_path)),
         :ok <- Clone.ensure_clone(base_path, repo_url, on_process) do
      Clone.fetch_and_reset(base_path, on_process)
    end
  end
end
