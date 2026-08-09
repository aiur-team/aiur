defmodule Aiur.Config.Boot do
  @moduledoc false

  alias Aiur.Config.Schema
  alias Aiur.GitHub.Config, as: GitHubConfig

  @spec resolve(Path.t(), Schema.t()) ::
          {:ok, %{path: Path.t(), repo: String.t(), base_branch: String.t()}}
          | {:error, term()}
  def resolve(path, settings) do
    case identity(settings) do
      {:ok, identity} -> {:ok, Map.put(identity, :path, path)}
      {:error, reason} -> {:error, {:invalid_boot_configuration, path, reason}}
    end
  end

  @spec identity(Schema.t()) :: {:ok, %{repo: String.t(), base_branch: String.t()}} | {:error, term()}
  def identity(settings) do
    with :ok <- validate(settings),
         {:ok, base_branch} <- base_branch(settings) do
      {:ok, %{repo: repo(settings), base_branch: base_branch}}
    end
  end

  @spec validate(Schema.t()) :: :ok | {:error, term()}
  def validate(settings) do
    cond do
      settings.tracker.kind == "github" and not explicit_github_repo?(settings) ->
        {:error, :missing_github_repo}

      not configured_base_branch?(settings.tracker.base_branch) ->
        {:error, :missing_base_branch}

      true ->
        :ok
    end
  end

  @spec base_branch(Schema.t()) :: {:ok, String.t()} | {:error, :missing_base_branch}
  def base_branch(%{tracker: %{base_branch: base_branch}}) do
    if configured_base_branch?(base_branch),
      do: {:ok, String.trim(base_branch)},
      else: {:error, :missing_base_branch}
  end

  defp explicit_github_repo?(settings) do
    match?({:ok, {_, _}}, GitHubConfig.parse_configured_repo(settings.tracker.github.repo))
  end

  defp configured_base_branch?(base_branch) when is_binary(base_branch),
    do: String.trim(base_branch) != ""

  defp configured_base_branch?(_base_branch), do: false

  defp repo(%{tracker: %{kind: "github", github: %{repo: repo}}}),
    do: String.trim(repo)

  defp repo(%{tracker: %{kind: "linear", linear: %{project_slug: slug}}})
       when is_binary(slug),
       do: String.trim(slug)

  defp repo(%{tracker: %{kind: kind}}) when is_binary(kind), do: kind
  defp repo(_settings), do: "unknown"
end
