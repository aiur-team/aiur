defmodule Aiur.Project do
  @moduledoc "One project (repository) the process serves: identity, config file and state directory."

  alias Aiur.Config.Paths

  @enforce_keys [:id, :repo, :config_path, :state_root]
  defstruct [:id, :repo, :config_path, :state_root]

  @type id :: String.t()
  @type t :: %__MODULE__{id: id(), repo: String.t(), config_path: Path.t(), state_root: Path.t()}

  @doc """
  Builds a project from a `projects:` machine entry. The id is the downcased
  repo, because GitHub treats `Owner/Repo` and `owner/repo` as one repository.
  """
  @spec from_machine_entry(%{repo: String.t(), config: Path.t()}, Path.t()) :: t()
  def from_machine_entry(%{repo: repo, config: config}, state_root) do
    %__MODULE__{id: String.downcase(repo), repo: repo, config_path: Path.expand(config), state_root: state_root}
  end

  @doc "State root of the implicit (no-context) project."
  @spec default_state_root() :: {:ok, Path.t()} | {:error, atom()}
  def default_state_root, do: Paths.decision_state_dir()
end
