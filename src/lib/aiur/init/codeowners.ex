defmodule Aiur.Init.Codeowners do
  @moduledoc """
  CODEOWNERS setup step for the `aiur init` wizard — creates the file and
  offers to add the Executor’s GitHub login to it.
  """

  alias Aiur.Codeowners
  alias Aiur.Codeowners.Edit
  alias Aiur.Init.Format

  @codeowners_file_name ".github/CODEOWNERS"
  @login_regex ~r/^[a-z\d](?:-?[a-z\d])*$/
  @max_login_length 39

  @spec setup_codeowners(Aiur.Init.io(), Aiur.Init.deps(), map()) :: :ok
  def setup_codeowners(io, deps, %{kind: "github"} = tracker) do
    repo_root = deps.repo_root.()

    repo_root
    |> then(fn repo_root -> Codeowners.file_path(repo_root: repo_root) end)
    |> maybe_create_codeowners(io, repo_root)
    |> maybe_add_operator_codeowner(io, deps, repo_root, tracker[:operator_account], tracker[:operator_account_skipped])
  end

  def setup_codeowners(_io, _deps, _tracker), do: :ok

  defp maybe_create_codeowners(nil, io, repo_root) do
    explain_codeowners_trust(io)

    if io.confirm.("Create #{@codeowners_file_name} for aiur's GitHub trust checks?", true) do
      case create_codeowners_file(repo_root) do
        {:ok, path} ->
          io.puts.(["Created: ", Format.dim(path)])
          path

        {:error, reason} ->
          io.puts.(["⚠️  Couldn't create #{@codeowners_file_name} (", inspect(reason), ")."])
          nil
      end
    else
      io.puts.("Skipped CODEOWNERS. Without it, only explicitly configured GitHub accounts are trusted by aiur.")
      nil
    end
  end

  defp maybe_create_codeowners(path, _io, _repo_root), do: path

  defp explain_codeowners_trust(io) do
    io.puts.([
      "\naiur uses CODEOWNERS to determine which GitHub accounts it will trust ",
      "when responding to PR/issue comments. Without CODEOWNERS, only explicitly ",
      "configured accounts are trusted."
    ])
  end

  defp create_codeowners_file(repo_root) do
    path = Path.join(repo_root, @codeowners_file_name)

    if File.regular?(path) do
      {:ok, path}
    else
      File.mkdir_p!(Path.dirname(path))

      File.write(path, """
      # aiur uses CODEOWNERS to decide which GitHub accounts are trusted for PR/issue comments.
      # Add owners below, for example:
      # * @your-github-login
      """)
      |> case do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_add_operator_codeowner(nil, _io, _deps, _repo_root, _operator, _operator_skipped), do: :ok

  defp maybe_add_operator_codeowner(_path, _io, _deps, _repo_root, _operator, true), do: :ok

  defp maybe_add_operator_codeowner(path, io, deps, repo_root, operator, _operator_skipped) do
    detected_login = operator || deps.github_login.()
    detected_login = detected_login |> Edit.normalize_login() |> valid_login_or_nil()

    if is_binary(detected_login) and codeowners_has_login?(repo_root, detected_login) do
      :ok
    else
      add_operator_codeowner(io, path, repo_root, detected_login)
    end
  end

  defp add_operator_codeowner(io, path, _repo_root, login) when is_binary(login) do
    case Edit.add_login(path, login) do
      {:updated, updated_path} -> io.puts.(["Updated: ", Format.dim(updated_path)])
      {:exists, _path} -> :ok
      {:error, reason} -> io.puts.(["⚠️  Couldn't update CODEOWNERS (", inspect(reason), ")."])
    end
  end

  defp add_operator_codeowner(io, path, repo_root, _missing_login) do
    case prompt_github_login(io, nil) do
      nil ->
        io.puts.("Skipped CODEOWNERS account entry because no GitHub login was provided.")

      login ->
        if codeowners_has_login?(repo_root, login), do: :ok, else: add_operator_codeowner(io, path, repo_root, login)
    end
  end

  defp prompt_github_login(io, default) do
    case Edit.normalize_login(io.input.("GitHub account to add to CODEOWNERS", default, "This account will be trusted to drive aiur from PR/issue comments.")) do
      nil ->
        nil

      login ->
        if valid_login?(login) do
          login
        else
          io.puts.("Enter a valid GitHub login (letters, numbers, and single hyphens).")
          prompt_github_login(io, default)
        end
    end
  end

  defp valid_login_or_nil(login) when is_binary(login), do: if(valid_login?(login), do: login)
  defp valid_login_or_nil(_login), do: nil

  defp valid_login?(login), do: String.length(login) <= @max_login_length and Regex.match?(@login_regex, login)

  defp codeowners_has_login?(repo_root, login) do
    case Codeowners.repo_ownership(repo_root: repo_root) do
      {:error, _reason} -> false
      context -> login in context.owners
    end
  end
end
