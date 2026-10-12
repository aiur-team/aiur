defmodule Aiur.MergePolicy do
  @moduledoc "Validated merge policy shared by policy consumers."

  @doc "Returns the configured policy as a plain map."
  @spec current() :: map()
  def current do
    policy = Aiur.Config.settings!().merge_policy
    policy |> Map.from_struct() |> Map.put(:main_watch, Map.from_struct(policy.main_watch))
  end

  @doc "Whether labels or changed repository paths require the full CI gate."
  @spec requires_full_ci?([String.t()], [String.t()]) :: boolean()
  def requires_full_ci?(labels, changed_paths) do
    policy = current()
    full_labels = Enum.map(policy.full_ci_labels, &String.downcase/1)

    Enum.any?(labels, &(String.downcase(&1) in full_labels)) or
      Enum.any?(policy.full_ci_paths, fn glob ->
        pattern = Regex.compile!("\\A" <> glob_pattern(glob) <> "\\z", "s")
        Enum.any?(changed_paths, &Regex.match?(pattern, &1))
      end)
  end

  # Match paths from the diff, including deleted files, without filesystem reads.
  defp glob_pattern("**/" <> rest), do: "(?:.*/)?" <> glob_pattern(rest)
  defp glob_pattern("**" <> rest), do: ".*" <> glob_pattern(rest)
  defp glob_pattern("*" <> rest), do: "[^/]*" <> glob_pattern(rest)
  defp glob_pattern("?" <> rest), do: "[^/]" <> glob_pattern(rest)
  defp glob_pattern(""), do: ""
  defp glob_pattern(<<char::utf8, rest::binary>>), do: Regex.escape(<<char::utf8>>) <> glob_pattern(rest)
end
