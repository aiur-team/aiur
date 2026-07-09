defmodule Aiur.Codeowners.Edit do
  @moduledoc """
  Pure CODEOWNERS content-editing companion to the `Aiur.Codeowners` parser —
  one source of truth for CODEOWNERS format facts. Handles adding logins,
  checking presence, and mutating file content without parsing ownership rules.
  """

  @spec add_login(Path.t(), String.t() | nil) ::
          {:updated, Path.t()} | {:exists, Path.t()} | {:error, term()}
  def add_login(path, login) do
    login = normalize_login(login)

    with true <- is_binary(login) and login != "",
         {:ok, content} <- File.read(path) do
      if has_login?(content, login) do
        {:exists, path}
      else
        write_codeowners_login(path, content, login)
      end
    else
      false -> {:error, :missing_github_login}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_codeowners_login(path, content, login) do
    case File.write(path, content_with_login(content, login)) do
      :ok -> {:updated, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec has_login?(String.t(), String.t() | nil) :: boolean()
  def has_login?(content, login) do
    login = normalize_login(login)

    content
    |> String.split(~r/\R/, trim: true)
    |> Enum.flat_map(&codeowner_tokens/1)
    |> Enum.any?(&(normalize_login(&1) == login))
  end

  defp codeowner_tokens(line) do
    line
    |> String.trim()
    |> case do
      "" -> []
      "#" <> _comment -> []
      line -> line |> String.split(~r/\s+/, trim: true) |> Enum.take_while(&(not String.starts_with?(&1, "#"))) |> Enum.drop(1)
    end
  end

  @spec content_with_login(String.t(), String.t()) :: String.t()
  def content_with_login(content, login) do
    case wildcard_rule_index(content) do
      nil ->
        append_codeowner_rule(content, login)

      index ->
        content
        |> String.split("\n", trim: false)
        |> List.update_at(index, &append_login_to_rule(&1, login))
        |> Enum.join("\n")
    end
  end

  defp wildcard_rule_index(content) do
    lines = String.split(content, "\n", trim: false)

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _index} -> wildcard_rule?(line) end)
    |> List.last()
    |> case do
      {_line, index} -> index
      nil -> nil
    end
  end

  defp wildcard_rule?(line) do
    case codeowner_rule_tokens(line) do
      ["*" | owners] when owners != [] -> true
      _ -> false
    end
  end

  defp codeowner_rule_tokens(line) do
    line
    |> String.trim()
    |> case do
      "" -> []
      "#" <> _comment -> []
      line -> line |> String.split(~r/\s+/, trim: true) |> Enum.take_while(&(not String.starts_with?(&1, "#")))
    end
  end

  defp append_login_to_rule(line, login) do
    case String.split(line, "#", parts: 2) do
      [rule, comment] -> String.trim_trailing(rule) <> " @#{login} #" <> comment
      [rule] -> String.trim_trailing(rule) <> " @#{login}"
    end
  end

  defp append_codeowner_rule(content, login) do
    separator = if content == "" or String.ends_with?(content, "\n"), do: "", else: "\n"
    content <> separator <> "* @#{login}\n"
  end

  @spec normalize_login(String.t() | nil) :: String.t() | nil
  def normalize_login(nil), do: nil

  def normalize_login(login) when is_binary(login) do
    login
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end
end
