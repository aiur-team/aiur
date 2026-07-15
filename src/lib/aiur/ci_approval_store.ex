defmodule Aiur.CIApprovalStore do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @type heads :: %{optional(String.t()) => String.t()}
  @type base_repair_state :: :repairing | :repaired
  @type base_repair_invalidation :: %{
          head_sha: String.t(),
          repaired_at: non_neg_integer(),
          repair_state: base_repair_state()
        }
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
        invalidations = Map.get(persisted, "base_repair_invalidations", %{})
        base_repair_invalidations = normalize_base_repair_invalidations(invalidations)

        %{
          approved_heads: normalize(Map.get(persisted, "approved_heads", %{})),
          test_failure_heads: normalize(Map.get(persisted, "test_failure_heads", %{})),
          base_repair_invalidations: base_repair_invalidations
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

  @doc """
  Durably records one pull-request base repair boundary.

  Unlike the lifecycle-wide best-effort `save/3`, this operation is strict:
  the caller must not mutate GitHub unless the `:repairing` marker is on disk.
  A per-path global lock keeps concurrent CI target tasks from overwriting one
  another while this read-modify-write operation preserves the other lifecycle
  fields.
  """
  @spec journal_base_repair(String.t(), base_repair_invalidation(), keyword()) ::
          :ok | {:error, term()}
  def journal_base_repair(target, invalidation, opts \\ [])

  def journal_base_repair(target, invalidation, opts)
      when is_binary(target) and is_map(invalidation) do
    path = Keyword.get(opts, :path, path_for())

    try do
      :global.trans({__MODULE__, path}, fn ->
        with {:ok, normalized_invalidation} <- normalize_invalidation(invalidation),
             {:ok, persisted} <- load_strict(path),
             invalidations =
               Map.put(persisted.base_repair_invalidations, target, normalized_invalidation),
             :ok <-
               write_strict(
                 path,
                 persisted.approved_heads,
                 persisted.test_failure_heads,
                 invalidations,
                 opts
               ) do
          :ok
        end
      end)
    rescue
      error -> {:error, {:base_repair_journal_failed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:base_repair_journal_failed, {kind, reason}}}
    end
  end

  def journal_base_repair(target, invalidation, _opts),
    do: {:error, {:invalid_base_repair_invalidation, target, invalidation}}

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
      repair_state = normalize_repair_state(map_value(invalidation, :repair_state))

      valid? =
        is_binary(target) and is_binary(head_sha) and head_sha != "" and
          is_integer(repaired_at) and repaired_at >= 0 and
          repair_state in [:repairing, :repaired]

      if valid? do
        Map.put(acc, target, %{
          head_sha: head_sha,
          repaired_at: repaired_at,
          repair_state: repair_state
        })
      else
        acc
      end
    end)
  end

  defp normalize_base_repair_invalidations(_invalidations), do: %{}

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp map_value(_map, _key), do: nil

  # Markers written before #1146 gained an explicit phase were produced only
  # after a confirmed repair, so treating a missing phase as `:repaired`
  # preserves their established restart behavior.
  defp normalize_repair_state(nil), do: :repaired
  defp normalize_repair_state(:repairing), do: :repairing
  defp normalize_repair_state(:repaired), do: :repaired
  defp normalize_repair_state("repairing"), do: :repairing
  defp normalize_repair_state("repaired"), do: :repaired
  defp normalize_repair_state(_other), do: nil

  defp normalize_invalidation(invalidation) do
    case normalize_base_repair_invalidations(%{"target" => invalidation}) do
      %{"target" => normalized} -> {:ok, normalized}
      _ -> {:error, {:invalid_base_repair_invalidation, invalidation}}
    end
  end

  defp load_strict(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{} = persisted} ->
        {:ok,
         %{
           approved_heads: normalize(Map.get(persisted, "approved_heads", %{})),
           test_failure_heads: normalize(Map.get(persisted, "test_failure_heads", %{})),
           base_repair_invalidations: normalize_base_repair_invalidations(Map.get(persisted, "base_repair_invalidations", %{}))
         }}

      {:ok, other} ->
        {:error, {:base_repair_journal_read_failed, {:unexpected_shape, other}}}

      {:error, reason} ->
        {:error, {:base_repair_journal_read_failed, reason}}
    end
  end

  defp write_strict(path, approved_heads, test_failure_heads, invalidations, opts) do
    writer = Keyword.get(opts, :write_fun, &JsonStore.write!/2)

    payload = %{
      "approved_heads" => normalize(approved_heads),
      "test_failure_heads" => normalize(test_failure_heads),
      "base_repair_invalidations" => normalize_base_repair_invalidations(invalidations)
    }

    case writer.(path, payload) do
      :ok -> :ok
      other -> {:error, {:base_repair_journal_write_failed, other}}
    end
  rescue
    error -> {:error, {:base_repair_journal_write_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:base_repair_journal_write_failed, {kind, reason}}}
  end

  defp empty_state,
    do: %{approved_heads: %{}, test_failure_heads: %{}, base_repair_invalidations: %{}}
end
