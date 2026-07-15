defmodule Aiur.CIApprovalStore do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @type heads :: %{optional(String.t()) => String.t()}
  @type base_repair_invalidation :: %{head_sha: String.t(), repaired_at: non_neg_integer()}
  @type base_repair_invalidations :: %{optional(String.t()) => base_repair_invalidation()}
  @type persisted_state :: %{
          approved_heads: heads(),
          test_failure_heads: heads(),
          base_repair_invalidations: base_repair_invalidations()
        }

  @doc """
  Loads the current-head SHAs that CI has approved for human review.

  Missing or unreadable state fails closed: the CI poller will re-evaluate the
  current head instead of trusting a stale approval.
  """
  @spec load() :: persisted_state()
  def load do
    case JsonStore.read(path_for(), %{}) do
      {:ok, %{} = persisted} ->
        %{
          approved_heads: normalize(Map.get(persisted, "approved_heads", %{})),
          test_failure_heads: normalize(Map.get(persisted, "test_failure_heads", %{})),
          base_repair_invalidations: normalize_base_repair_invalidations(Map.get(persisted, "base_repair_invalidations", %{}))
        }

      {:ok, _other} ->
        Logger.warning("CI approval store at #{path_for()} has an unexpected shape; starting empty")
        empty_state()

      {:error, reason} ->
        Logger.warning("CI approval store at #{path_for()} could not be read: #{inspect(reason)}; starting empty")
        empty_state()
    end
  end

  @doc """
  Atomically persists approved PR heads and fail-closed lifecycle markers.
  Persistence is best-effort so an I/O failure never interrupts a completed CI
  lifecycle transition.
  """
  @spec save(heads(), heads(), base_repair_invalidations()) :: :ok
  def save(approved_heads, test_failure_heads, base_repair_invalidations \\ %{})

  def save(approved_heads, test_failure_heads, base_repair_invalidations)
      when is_map(approved_heads) and is_map(test_failure_heads) and is_map(base_repair_invalidations) do
    JsonStore.write!(path_for(), %{
      "approved_heads" => normalize(approved_heads),
      "test_failure_heads" => normalize(test_failure_heads),
      "base_repair_invalidations" => normalize_base_repair_invalidations(base_repair_invalidations)
    })

    :ok
  rescue
    error ->
      Logger.warning("CI approval store persistence failed at #{path_for()}: #{Exception.message(error)}")
      :ok
  end

  @doc false
  @spec path_for() :: Path.t()
  def path_for do
    Application.get_env(:aiur, :ci_approval_store_path) ||
      Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.ci-approvals.json")
  end

  defp normalize(heads) when is_map(heads) do
    Enum.reduce(heads, %{}, fn
      {target, head_sha}, acc when is_binary(target) and is_binary(head_sha) and head_sha != "" ->
        Map.put(acc, target, head_sha)

      _entry, acc ->
        acc
    end)
  end

  defp normalize(_heads), do: %{}

  defp normalize_base_repair_invalidations(invalidations) when is_map(invalidations) do
    Enum.reduce(invalidations, %{}, fn {target, invalidation}, acc ->
      head_sha = map_value(invalidation, :head_sha)
      repaired_at = map_value(invalidation, :repaired_at)

      if is_binary(target) and is_binary(head_sha) and head_sha != "" and is_integer(repaired_at) and repaired_at >= 0 do
        Map.put(acc, target, %{head_sha: head_sha, repaired_at: repaired_at})
      else
        acc
      end
    end)
  end

  defp normalize_base_repair_invalidations(_invalidations), do: %{}

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp map_value(_map, _key), do: nil

  defp empty_state,
    do: %{approved_heads: %{}, test_failure_heads: %{}, base_repair_invalidations: %{}}
end
