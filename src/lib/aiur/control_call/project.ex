defmodule Aiur.ControlCall.Project do
  @moduledoc """
  Picks the project a control call works on a multi-project gateway.

  The CLI sends `project:` (explicit `--project`, strict) and `project_hint:`
  (repo of the caller's directory, only a tie-breaker) inside the call's last
  keyword. `split_raw/1` strips both before allowlist validation, so no
  allowlist row names them.
  """

  alias Aiur.ControlCall.Literal
  alias Aiur.Project.Context
  alias Aiur.Project.Registry

  # {module segments, function} pairs whose CLI wires `aiur_project_kw`. Any other
  # function carrying `project:` is refused rather than silently ignoring it.
  @project_scoped [
    {[:Aiur, :AgentControlCLI], :queue},
    {[:Aiur, :AgentControlCLI], :lane},
    {[:Aiur, :AgentControlCLI], :epic},
    {[:Aiur, :AgentControlCLI], :feature},
    {[:Aiur, :AgentControlCLI], :units},
    {[:Aiur, :AgentControlCLI], :build_orders},
    {[:Aiur, :AgentControlCLI], :analytics},
    {[:Aiur, :AgentControlCLI], :set_setting},
    {[:Aiur, :AgentControlCLI], :unset_setting}
  ]

  @spec project_scoped() :: [{[atom()], atom()}]
  def project_scoped, do: @project_scoped

  @doc "Strips `project:`/`project_hint:` from the raw (AST) args; returns `{project, hint, raw_args}`."
  @spec split_raw(list()) :: {:ok, String.t() | nil, String.t() | nil, list()} | {:error, :non_literal_argument}
  def split_raw(raw_args) do
    case List.last(raw_args) do
      keyword when is_list(keyword) and keyword != [] ->
        {found, rest} = Enum.split_with(keyword, &match?({key, _} when key in [:project, :project_hint], &1))

        with {:ok, project} <- value(found, :project), {:ok, hint} <- value(found, :project_hint) do
          {:ok, project, hint, List.replace_at(raw_args, -1, rest)}
        end

      _ ->
        {:ok, nil, nil, raw_args}
    end
  end

  defp value(found, key) do
    case List.keyfind(found, key, 0) do
      nil ->
        {:ok, nil}

      {^key, ast} ->
        case Literal.convert([ast]) do
          {:ok, [value]} when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, :non_literal_argument}
        end
    end
  end

  @spec resolve(String.t() | nil, String.t() | nil, [String.t()]) ::
          {:ok, String.t() | nil} | {:error, {:ambiguous, [String.t()]} | {:unknown, String.t(), [String.t()]}}
  def resolve(project, hint, repos) do
    repos = Enum.sort(repos)

    case {repos, project && find(repos, project)} do
      {[], _} -> {:ok, nil}
      {_, nil} when is_binary(project) -> {:error, {:unknown, project, repos}}
      {_, repo} when is_binary(repo) -> {:ok, repo}
      {[only], nil} -> {:ok, only}
      {_, nil} -> if(hint && find(repos, hint), do: {:ok, find(repos, hint)}, else: {:error, {:ambiguous, repos}})
    end
  end

  defp find(repos, name), do: Enum.find(repos, &(String.downcase(&1) == String.downcase(name)))

  @doc """
  Runs a project-keyworded expression from the local CLI through `ControlCall`, so a local
  call resolves its project exactly as a remote one does. Prints what the command printed.
  """
  @spec run_local(String.t()) :: :ok
  def run_local(expression) do
    case Aiur.ControlCall.parse(expression, remote: false) do
      {:ok, call} ->
        {:ok, output} = Aiur.ControlCall.run(call, 3_600_000, Aiur.ControlCall.actor())
        IO.write(output)

      {:error, reason} ->
        IO.write("__AIUR_CONTROL_ERROR__:control call refused: #{inspect(reason)}\n__AIUR_CONTROL_EXIT__:64\n")
    end
  end

  @doc "Resolves against the running projects and puts the context on the calling process. Returns a user message on failure."
  @spec activate(String.t() | nil, String.t() | nil, (String.t() -> Aiur.Project.t() | nil)) :: :ok | {:error, String.t()}
  def activate(project, hint, lookup \\ &Registry.project/1) do
    # Running projects only: a failed tree cannot serve a command.
    repos = for id <- Registry.project_ids(), project = lookup.(id), do: project.repo

    case resolve(project, hint, repos) do
      {:ok, nil} ->
        single_project(project)

      {:ok, repo} ->
        case lookup.(repo) do
          %Aiur.Project{} = found ->
            Context.put(found)
            :ok

          # The tree stopped between the list and the lookup: never fall back to the bare names.
          nil ->
            {:error, unknown_message(repo, repos)}
        end

      {:error, {:ambiguous, repos}} ->
        {:error, "pick a project: " <> Enum.join(repos, ", ")}

      {:error, {:unknown, name, repos}} ->
        {:error, unknown_message(name, repos)}
    end
  end

  # No `projects:` registry: the gateway serves its one configured tracker repo, so a different
  # explicit project is refused. Context stays unset, keeping single-project behaviour.
  defp single_project(nil), do: :ok

  defp single_project(project) do
    case tracker_repo() do
      nil -> :ok
      repo -> if String.downcase(repo) == String.downcase(project), do: :ok, else: {:error, unknown_message(project, [repo])}
    end
  end

  defp tracker_repo do
    case Application.get_env(:aiur, :project_identity_source, Aiur.Tracker).project_identity() do
      repo when is_binary(repo) and repo != "" -> repo
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp unknown_message(name, repos), do: "unknown project '#{name}'; this gateway has: " <> Enum.join(repos, ", ")
end
