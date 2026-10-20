defmodule Aiur.LandingWatch.QuarantineEvidence do
  @moduledoc """
  Decides which failures may count toward quarantine.

  A test is a flake only with evidence that it also passes: a base-branch failure counts
  once a rerun of the failing commit passed it, and never when the failing change touched
  the test or the lib file it mirrors. A test that fails in the newest base-branch run is a
  regression for the main-watch fixer; merge-group failures recorded meanwhile never count.
  """

  @guard_module "Aiur.TestSupport.OrchestratorGuard"
  @guard_name "plain ExUnit tests broke Aiur.Orchestrator"

  @doc "The single identity every OrchestratorGuard failure is filed under; the test it names is never quarantined."
  @spec guard_failure(String.t(), String.t()) :: map()
  def guard_failure(named, job) do
    excerpt = "Last finished test named by the guard (attribution timing, not proof of cause): #{named}"
    %{module: @guard_module, name: @guard_name, job: job, excerpt: excerpt, path: nil}
  end

  @doc "Whether a change to `paths` could explain a failure of the test at `test_path`."
  @spec touched?(String.t() | nil, [String.t()]) :: boolean()
  def touched?(test_path, paths) when is_binary(test_path) and is_list(paths), do: test_path in paths or lib_path(test_path) in paths
  def touched?(_test_path, _paths), do: false

  defp lib_path("src/test/" <> rest), do: "src/lib/" <> String.replace_suffix(rest, "_test.exs", ".ex")
  defp lib_path(_path), do: nil

  @doc "Identities that fail in the newest complete base-branch run."
  @spec red_on_main([map()]) :: [String.t()]
  def red_on_main(history) do
    case Enum.max_by(history, &(Map.get(&1, :completed_at) || 0), fn -> nil end) do
      nil -> []
      latest -> failing(latest) || []
    end
  end

  @doc """
  Whether the failing commit passed this test when it was rerun. Only a rerun of the same
  commit proves a flake: a later green commit may be the fix of a regression.
  """
  @spec passed_on_rerun?([map()], map()) :: boolean()
  def passed_on_rerun?(history, %{"identity" => identity, "head_sha" => sha}) when is_binary(sha) do
    # The main watcher keeps one entry per commit, so a rerun replaces the failing entry.
    Enum.any?(history, fn entry ->
      failed = failing(entry)
      Map.get(entry, :sha) == sha and is_list(failed) and identity not in failed
    end)
  end

  def passed_on_rerun?(_history, _row), do: false

  # nil when the entry cannot prove which tests failed.
  defp failing(%{digest: %{checks: checks}}) when is_list(checks) do
    if Enum.all?(checks, &is_list(&1[:tests])), do: checks |> Enum.flat_map(& &1.tests) |> Enum.map(& &1.identity), else: nil
  end

  defp failing(_entry), do: nil
end
