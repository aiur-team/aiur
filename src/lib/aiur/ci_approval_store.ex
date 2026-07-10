defmodule Aiur.CIApprovalStore do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @type heads :: %{optional(String.t()) => String.t()}
  @type persisted_state :: %{approved_heads: heads(), test_failure_heads: heads()}

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
          test_failure_heads: normalize(Map.get(persisted, "test_failure_heads", %{}))
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
  Atomically persists approved PR heads. Persistence is best-effort so an I/O
  failure never interrupts a completed CI lifecycle transition.
  """
  @spec save(heads(), heads()) :: :ok
  def save(approved_heads, test_failure_heads) when is_map(approved_heads) and is_map(test_failure_heads) do
    JsonStore.write!(path_for(), %{
      "approved_heads" => normalize(approved_heads),
      "test_failure_heads" => normalize(test_failure_heads)
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

  defp empty_state, do: %{approved_heads: %{}, test_failure_heads: %{}}
end
