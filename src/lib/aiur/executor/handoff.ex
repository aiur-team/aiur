defmodule Aiur.Executor.Handoff do
  @moduledoc """
  Seeds the replaceable, machine-local handoff for a repository's Executor.
  """

  alias Aiur.Init.Templates
  alias Aiur.RepoBase

  @legacy_path ["docs", "build-order", "EXECUTOR-HANDOFF.md"]

  @spec ensure(String.t(), Path.t() | nil) :: :ok | {:error, term()}
  def ensure(repo_url, source_root \\ nil) when is_binary(repo_url) do
    target = RepoBase.handoff_path(repo_url)

    if File.regular?(target) do
      :ok
    else
      repo_url
      |> initial_contents(source_root)
      |> write_initial_handoff(target)
    end
  end

  defp initial_contents(_repo_url, nil), do: {:ok, Templates.executor_handoff_template()}

  defp initial_contents(repo_url, source_root) when is_binary(source_root) do
    source = Path.join([source_root | @legacy_path])

    if File.regular?(source) do
      case File.read(source) do
        {:ok, contents} -> {:ok, current_section(contents)}
        {:error, reason} -> {:error, {:legacy_handoff_read_failed, repo_url, source, reason}}
      end
    else
      {:ok, Templates.executor_handoff_template()}
    end
  end

  defp write_initial_handoff({:ok, contents}, target) do
    case File.write(target, ensure_trailing_newline(contents), [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:executor_handoff_write_failed, target, reason}}
    end
  end

  defp write_initial_handoff({:error, _reason} = error, _target), do: error

  # The tracked legacy document orders its current handoff before a horizontal
  # rule and every superseded checkpoint. Preserve that one current section,
  # rather than carrying a multi-session archive into the living state file.
  defp current_section(contents) do
    case Regex.run(~r/^## [^\n]+\n.*?(?=^---\s*$|^## [^\n]+|\z)/ms, contents) do
      [section] -> section
      _ -> Templates.executor_handoff_template()
    end
  end

  defp ensure_trailing_newline(contents), do: String.trim_trailing(contents) <> "\n"
end
