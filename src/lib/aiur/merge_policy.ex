defmodule Aiur.MergePolicy do
  @moduledoc "Validated merge policy shared by policy consumers."

  @doc "Returns the configured policy as a plain map."
  @spec current() :: map()
  def current do
    policy = Aiur.Config.settings!().merge_policy
    policy |> Map.from_struct() |> Map.put(:main_watch, Map.from_struct(policy.main_watch))
  end

  @doc "Whether the configured base-CI policy gives a ticket fixer priority."
  @spec fixer_ticket?(term(), map()) :: boolean()
  def fixer_ticket?(issue, watch \\ current().main_watch)
  def fixer_ticket?(%{labels: labels}, watch) when is_list(labels), do: watch.on_red == "dispatch_fixer" and Enum.any?(labels, &(String.downcase(&1) == String.downcase(watch.fixer_label)))
  def fixer_ticket?(_issue, _watch), do: false

  @doc "Whether labels or changed repository paths require the full CI gate."
  @spec requires_full_ci?([String.t()], [String.t()]) :: boolean()
  def requires_full_ci?(labels, changed_paths) do
    requires_full_ci?(labels, changed_paths, current())
  end

  @doc false
  @spec requires_full_ci?([String.t()], [String.t()], map()) :: boolean()
  def requires_full_ci?(labels, changed_paths, policy) do
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
