defmodule Aiur.Events.PostDeployChecks do
  @moduledoc "Extract post-deploy checklist lines from a PR's Local tests section."

  @spec from_pr_body(term()) :: [String.t()]
  def from_pr_body(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({false, false, []}, &collect_line/2)
    |> elem(2)
    |> then(fn checks -> Enum.reverse(checks) end)
  end

  def from_pr_body(_body), do: []

  defp post_deploy_check_line(line) do
    case Regex.run(~r/^\s*(?:[-*]\s*)?Post-deploy check:\s*(\S.*)$/i, String.trim(line)) do
      [_, text] -> [String.slice(text, 0, 2_000)]
      _ -> []
    end
  end

  defp collect_line(line, {in_local_tests?, in_fence?, checks}) do
    cond do
      Regex.match?(~r/^\s*```/, line) -> {in_local_tests?, not in_fence?, checks}
      in_fence? -> {in_local_tests?, in_fence?, checks}
      Regex.match?(~r/^\s*##\s+Local tests\s*$/i, line) -> {true, false, checks}
      Regex.match?(~r/^\s*[#]{1,6}\s+/, line) -> {false, false, checks}
      in_local_tests? and length(checks) < 20 -> {true, false, post_deploy_check_line(line) ++ checks}
      true -> {in_local_tests?, false, checks}
    end
  end
end
