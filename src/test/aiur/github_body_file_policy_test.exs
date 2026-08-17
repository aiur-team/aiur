defmodule Aiur.GitHubBodyFilePolicyTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @source_paths [
    ".claude/skills",
    ".codex/skills",
    "scripts",
    "packaging",
    "src/lib",
    "src/priv"
  ]

  test "Aiur source never passes gh message bodies inline" do
    {paths, 0} = System.cmd("git", ["ls-files", "--" | @source_paths], cd: @repo_root)

    offenders =
      paths
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&inline_gh_body_offenders/1)

    assert offenders == []
  end

  test "guard distinguishes payload files from shell variables" do
    assert inline_gh_body_line?(~s(gh pr comment 42 --body "$reply"))
    assert inline_gh_body_line?(~s(gh api graphql -f body="$reply"))
    assert inline_gh_body_line?(~s(  -F "body=$reply" \\))

    refute inline_gh_body_line?(~s(gh pr comment 42 --body-file "$reply_file"))
    refute inline_gh_body_line?(~s(gh api graphql -F "body=@$reply_file"))
  end

  defp inline_gh_body_offenders(path) do
    case System.cmd("git", ["show", ":#{path}"], cd: @repo_root, stderr_to_stdout: true) do
      {contents, 0} ->
        offenders_from_contents(contents, path)

      {_error, _status} ->
        []
    end
  end

  defp offenders_from_contents(contents, path) do
    if String.valid?(contents) do
      contents
      |> executable_source_lines(path)
      |> Enum.filter(fn {line, _line_number} -> inline_gh_body_line?(line) end)
      |> Enum.map(fn {_line, line_number} -> "#{path}:#{line_number}" end)
    else
      []
    end
  end

  defp executable_source_lines(contents, path) do
    lines = contents |> String.split("\n") |> Enum.with_index(1)

    if Path.extname(path) == ".md",
      do: markdown_executable_lines(lines),
      else: Enum.reject(lines, &comment_line?/1)
  end

  defp markdown_executable_lines(lines) do
    {executable, _inside_fence?} =
      Enum.reduce(lines, {[], false}, fn {line, _line_number} = numbered_line, {acc, inside_fence?} ->
        if String.starts_with?(String.trim_leading(line), "```") do
          {acc, not inside_fence?}
        else
          {if(inside_fence?, do: [numbered_line | acc], else: acc), inside_fence?}
        end
      end)

    Enum.reverse(executable)
  end

  defp comment_line?({line, _line_number}), do: String.starts_with?(String.trim_leading(line), ["#", "//"])

  defp inline_gh_body_line?(line) do
    gh_command = ~r/(?:^|\s)gh\s+.*(?:--body(?:\s|=)|-b(?:\s|=)|-[fF]\s+["']?body=(?!@))/
    continuation = ~r/^\s*(?:--body(?:\s|=)|-b(?:\s|=)|-[fF]\s+["']?body=(?!@))/
    Regex.match?(gh_command, line) or Regex.match?(continuation, line)
  end
end
