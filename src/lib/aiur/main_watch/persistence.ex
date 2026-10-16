defmodule Aiur.MainWatch.Persistence do
  @moduledoc false
  alias Aiur.GitHub.ResourceStore
  alias Aiur.MainWatch.State

  @spec load(String.t(), String.t()) :: map()
  def load(repo, branch) do
    case ResourceStore.fetch(key(repo, branch)) do
      {:ok, %{data: %{"state" => encoded}}} -> decode(encoded)
      _ -> empty()
    end
  end

  @spec save(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def save(repo, branch, data) do
    encoded = data |> :erlang.term_to_binary([:compressed]) |> Base.encode64()

    with :ok <- ResourceStore.put_resource(key(repo, branch), %{"state" => encoded}, source: :fetch), do: ResourceStore.flush()
  end

  @spec reserve_rerun(String.t(), String.t(), integer(), pos_integer()) :: :ok | {:error, term()}
  def reserve_rerun(repo, scope, now, window) do
    key = ResourceStore.key_for_repo(:main_watch, repo, "rerun:" <> scope)

    case ResourceStore.fetch(key) do
      {:ok, %{data: %{"at" => at}}} when now - at < window ->
        {:error, :already_attempted}

      _ ->
        with :ok <- ResourceStore.put_resource(key, %{"at" => now}, source: :fetch), do: ResourceStore.flush()
    end
  end

  @spec empty() :: map()
  def empty do
    %{
      state: State.new(),
      pending: [],
      commits: [],
      early_merges: [],
      merge_groups: [],
      canary_at: nil,
      unavailable: false,
      last_error: nil,
      last_completed_at: nil,
      started_at: System.system_time(:millisecond)
    }
  end

  defp key(repo, branch), do: ResourceStore.key_for_repo(:main_watch, repo, branch)

  defp decode(encoded) do
    with {:ok, binary} <- Base.decode64(encoded),
         %{state: %{status: status}, pending: pending} = data <- :erlang.binary_to_term(binary, [:safe]),
         true <- status in [:unknown, :green, :red] and is_list(pending) do
      Map.merge(empty(), data)
    else
      _ -> empty()
    end
  rescue
    ArgumentError -> empty()
  end
end
