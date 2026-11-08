defmodule Aiur.Project do
  @moduledoc "One project (repository) the process serves: identity, config file and state directory."

  alias Aiur.Config.Paths
  alias Aiur.Project.Context

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

  @doc "Scopes a machine-level key by the caller's project; the bare key with no context."
  @spec scope_key(term()) :: term()
  def scope_key(key) do
    case Aiur.Project.Context.current_id() do
      nil -> key
      id -> {id, key}
    end
  end

  @doc "Scopes a PubSub topic by the caller's project; the bare topic with no context."
  @spec topic(String.t()) :: String.t()
  def topic(base) do
    case Aiur.Project.Context.current_id() do
      nil -> base
      id -> "project:" <> id <> ":" <> base
    end
  end

  @doc """
  Name a project-scoped process registers under: `module` itself with no project,
  else a via tuple over `Aiur.ProjectRegistry` keyed by the downcased project id.
  """
  @spec name(module(), id() | nil) :: GenServer.server()
  def name(module, project_id \\ Context.current_id())
  def name(module, nil), do: module
  def name(module, id), do: {:via, Registry, {Aiur.ProjectRegistry, {String.downcase(id), module}}}

  @doc "Lookup side of `name/2`; a function-head default evaluates it per call, so it follows the caller's project."
  @spec whereis(module(), id() | nil) :: GenServer.server()
  def whereis(module, project_id \\ Context.current_id()), do: name(module, project_id)

  @doc "Project-owned state root: the current project's, else the machine's `decision_state_dir/0`."
  @spec state_dir() :: {:ok, Path.t()} | {:error, atom()}
  def state_dir do
    case Context.current() do
      %__MODULE__{state_root: root} -> {:ok, root}
      nil -> Paths.decision_state_dir()
    end
  end

  @doc "State root of the implicit (no-context) project."
  @spec default_state_root() :: {:ok, Path.t()} | {:error, atom()}
  def default_state_root, do: Paths.decision_state_dir()

  @doc """
  The GenServer name for `module` in the current project: a `Registry` via-tuple
  with a project context, the bare module (today's bare name) without.
  """
  @spec via(module()) :: GenServer.server()
  def via(module), do: name(module)

  @doc "Adds the caller's project to start options, for a server that must work for it."
  @spec carry(keyword()) :: keyword()
  def carry(opts), do: Keyword.put(opts, :project, Context.current())

  @doc "Called in a server's `init/1`: takes on the project `carry/1` handed it."
  @spec adopt(keyword()) :: :ok
  def adopt(opts) do
    if project = opts[:project], do: Context.put(project)
    :ok
  end
end
