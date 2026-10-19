defmodule Aiur.TestRunState do
  @moduledoc false

  # Whether this daemon is an `aiurdev --test` / `--test3` sandbox run.
  @spec active?() :: boolean()
  def active?, do: System.get_env("AIUR_DEV_TEST_TICKET_IDS") not in [nil, ""]

  @spec scope_root() :: {:ok, Path.t()} | {:error, :missing_test_state_dir} | :ordinary
  def scope_root do
    case {System.get_env("AIUR_DEV_TEST_TICKET_IDS"), System.get_env("AIUR_DEV_TEST_STATE_DIR")} do
      {scope, root} when is_binary(scope) and scope != "" and is_binary(root) and root != "" -> {:ok, root}
      {scope, _root} when is_binary(scope) and scope != "" -> {:error, :missing_test_state_dir}
      _ -> :ordinary
    end
  end

  @spec decision_state_override(String.t() | nil) :: {:ok, String.t()} | {:error, atom()} | :resolve
  def decision_state_override(configured_path) do
    case scope_root() do
      {:ok, _root} -> :resolve
      {:error, reason} -> {:error, reason}
      :ordinary -> configured_override(configured_path)
    end
  end

  @spec decision_state_root(Path.t()) :: Path.t()
  def decision_state_root(fallback) do
    case scope_root() do
      {:ok, root} -> root
      _ -> state_root_fallback(fallback)
    end
  end

  defp state_root_fallback(fallback) do
    case System.get_env("AIUR_BG_STATE_DIR") do
      root when is_binary(root) and root != "" -> root
      _ -> fallback
    end
  end

  defp configured_override(path) when is_binary(path) and path != "", do: {:ok, path}
  defp configured_override(_path), do: :resolve
end
