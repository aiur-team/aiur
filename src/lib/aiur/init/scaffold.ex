defmodule Aiur.Init.Scaffold do
  @moduledoc """
  Filesystem scaffolding for the `.aiur/` layout used by `aiur init`.

  This module owns path selection, never-clobber config and sibling-file writers,
  `.gitignore` updates, `.env` scaffolding, and the small announce wrappers used
  by the wizard flow.
  """

  alias Aiur.Init.{Dotenv, Format, Templates}

  @config_file_name ".aiur/config"
  @legacy_config_file_name ".aiurconfig"
  @alerts_file_name "alerts"
  @aiurhooks_file_name "hooks"
  @prewarm_file_name "prewarm"
  @env_file_name ".env"
  @github_token_key "GITHUB_TOKEN"
  @gitignore_entry ".aiur/"

  @doc false
  @spec config_target(atom()) :: Path.t()
  def config_target(:global), do: Path.expand("~/" <> @config_file_name)
  def config_target(_location), do: Path.join(File.cwd!(), @config_file_name)

  @doc false
  @spec legacy_config_target(atom()) :: Path.t()
  def legacy_config_target(:global), do: Path.expand("~/" <> @legacy_config_file_name)
  def legacy_config_target(_location), do: Path.join(File.cwd!(), @legacy_config_file_name)

  @doc false
  @spec global_alerts_path() :: Path.t()
  def global_alerts_path, do: Path.expand("~/.aiur/" <> @alerts_file_name)

  @doc false
  @spec existing_config_path(Path.t()) :: String.t() | nil
  def existing_config_path(target) do
    if File.regular?(target), do: target
  end

  @doc false
  @spec existing_alerts_path(Path.t()) :: String.t() | nil
  def existing_alerts_path(path) do
    if File.regular?(path), do: path
  end

  @doc false
  @spec write_config(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def write_config(target, yaml) do
    File.mkdir_p!(Path.dirname(target))

    case File.write(target, yaml) do
      :ok -> {:ok, target}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec append_config_section(Path.t(), iodata()) :: {:ok, Path.t()} | {:error, term()}
  def append_config_section(target, block) do
    with {:ok, existing} <- File.read(target),
         body = String.trim_trailing(existing, "\n") <> "\n\n" <> IO.iodata_to_binary(block),
         :ok <- File.write(target, body) do
      {:ok, target}
    end
  end

  @doc false
  @spec write_prompt_file(Path.t(), String.t(), String.t() | nil) :: {:created | :exists, Path.t()}
  def write_prompt_file(target, prompt_file, repo) do
    path = Path.expand(prompt_file, Path.dirname(target))

    if File.regular?(path) do
      {:exists, path}
    else
      File.write!(path, Templates.prompt_file_scaffold(repo))
      {:created, path}
    end
  end

  @doc false
  @spec write_aiurhooks(Path.t()) :: {:created | :exists, Path.t()}
  def write_aiurhooks(target) do
    path = Path.join(Path.dirname(target), @aiurhooks_file_name)

    if File.regular?(path) do
      {:exists, path}
    else
      File.write!(path, Templates.aiurhooks_template())
      {:created, path}
    end
  end

  @doc false
  @spec write_prewarm_file(Path.t(), String.t()) :: {:created | :exists, Path.t()}
  def write_prewarm_file(target, command) do
    path = Path.join(Path.dirname(target), @prewarm_file_name)

    if File.regular?(path) do
      {:exists, path}
    else
      File.write!(path, command <> "\n")
      {:created, path}
    end
  end

  @doc false
  @spec add_gitignore_entry(String.t()) :: {:added | :exists, Path.t()}
  def add_gitignore_entry(entry), do: add_gitignore_entry(File.cwd!(), entry)

  @doc false
  @spec add_gitignore_entry(Path.t(), String.t()) :: {:added | :exists, Path.t()}
  def add_gitignore_entry(dir, entry) do
    path = Path.join(dir, ".gitignore")

    existing =
      case File.read(path) do
        {:ok, content} -> content
        {:error, _} -> ""
      end

    present? = existing |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.member?(entry)

    if present? do
      {:exists, path}
    else
      separator = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
      File.write!(path, existing <> separator <> entry <> "\n")
      {:added, path}
    end
  end

  @doc false
  @spec ensure_env(String.t()) :: {:created | :exists, Path.t()}
  def ensure_env(env_content) do
    cwd = File.cwd!()
    env_path = Path.join(cwd, @env_file_name)

    if File.regular?(env_path) do
      existing = File.read!(env_path)
      append_github_token_if_missing(env_path, existing, env_content)
      {:exists, env_path}
    else
      File.write!(env_path, env_content)
      {:created, env_path}
    end
  end

  defp append_github_token_if_missing(env_path, existing, env_content) do
    unless github_token_present?(existing) do
      separator = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
      File.write!(env_path, separator <> env_content, [:append])
    end
  end

  defp github_token_present?(content) do
    content
    |> Dotenv.parse(include_empty: true)
    |> Enum.any?(fn {key, _value} -> key == @github_token_key end)
  end

  @doc false
  @spec same_path?(Path.t(), Path.t()) :: boolean()
  def same_path?(left, right), do: Path.expand(left) == Path.expand(right)

  @doc false
  @spec ensure_prompt_file(Aiur.Init.io(), Aiur.Init.deps(), Path.t(), String.t() | nil, String.t() | nil) :: :ok
  def ensure_prompt_file(_io, _deps, _target, prompt_file, _repo) when prompt_file in [nil, ""], do: :ok

  def ensure_prompt_file(io, deps, target, prompt_file, repo) do
    case deps.ensure_prompt_file.(target, prompt_file, repo) do
      {:created, path} -> io.puts.(["Created: ", Format.dim(path)])
      {:exists, _path} -> :ok
    end
  end

  @doc false
  @spec ensure_aiurhooks(Aiur.Init.io(), Aiur.Init.deps(), Path.t()) :: :ok
  def ensure_aiurhooks(io, deps, target) do
    case deps.ensure_aiurhooks.(target) do
      {:created, path} -> io.puts.(["Created: ", Format.dim(path)])
      {:exists, _path} -> :ok
    end
  end

  @doc false
  @spec maybe_offer_gitignore(Aiur.Init.io(), Aiur.Init.deps(), atom()) :: :ok
  def maybe_offer_gitignore(_io, _deps, :global), do: :ok

  def maybe_offer_gitignore(io, deps, _repo_local) do
    if io.confirm.("Add #{@gitignore_entry} to .gitignore?", false) do
      case deps.add_gitignore_entry.(@gitignore_entry) do
        {:added, path} -> io.puts.(["Updated: ", Format.dim(path)])
        {:exists, _path} -> :ok
      end
    else
      :ok
    end
  end

  @doc false
  @spec setup_env(Aiur.Init.io(), Aiur.Init.deps(), map()) :: :ok
  def setup_env(io, deps, %{kind: "github"}) do
    {status, path} = deps.ensure_env.(Templates.env_content())

    case status do
      :created -> io.puts.(["Created: ", Format.dim(path)])
      :exists -> io.puts.(["Found: ", Format.dim(path)])
    end
  end

  def setup_env(_io, _deps, _tracker), do: :ok
end
