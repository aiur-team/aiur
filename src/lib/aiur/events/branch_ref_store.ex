defmodule Aiur.Events.BranchRefStore do
  @moduledoc """
  Owns the restart-durable latest validated remote ref for each ticket branch.

  Branch-push events update the store immediately. `LsRemoteTicker` replaces
  the baseline after every successful poll, including its silent bootstrap,
  so corroboration survives consumer subscription ordering and is restored
  after an application restart.
  """

  use GenServer

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Events.GithubKeys
  alias Aiur.JsonStore

  @type metadata :: %{ref: String.t(), sha: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec record(String.t(), String.t(), GenServer.server()) :: :ok | :error
  def record(ref, sha, server \\ __MODULE__)

  def record(ref, sha, server) when is_binary(ref) and is_binary(sha) do
    GenServer.call(server, {:record, ref, sha})
  end

  def record(_ref, _sha, _server), do: :error

  @spec replace(map(), GenServer.server()) :: :ok
  def replace(refs, server \\ __MODULE__) when is_map(refs) do
    GenServer.call(server, {:replace, refs})
  end

  @spec latest(String.t() | integer(), GenServer.server()) :: metadata() | nil
  def latest(identifier, server \\ __MODULE__) do
    GenServer.call(server, {:latest, to_string(identifier)})
  end

  @doc false
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    {:ok, %{path: path, refs: load(path)}}
  end

  @impl true
  def handle_call({:record, ref, sha}, _from, state) do
    case validated_entry(ref, sha) do
      {:ok, identifier, metadata} ->
        refs = Map.put(state.refs, identifier, metadata)
        {:reply, :ok, persist_if_changed(state, refs)}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:replace, refs}, _from, state) do
    {:reply, :ok, persist_if_changed(state, validated_refs(refs))}
  end

  def handle_call({:latest, identifier}, _from, state) do
    {:reply, Map.get(state.refs, identifier), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, persist_if_changed(state, %{})}
  end

  defp load(path) do
    case JsonStore.read(path, %{}) do
      {:ok, refs} when is_map(refs) -> decode_refs(refs)
      {:error, reason} -> log_load_failure(path, reason)
      _other -> %{}
    end
  end

  defp decode_refs(refs) do
    Enum.reduce(refs, %{}, fn
      {identifier, metadata}, acc when is_map(metadata) ->
        ref = Map.get(metadata, "ref") || Map.get(metadata, :ref)
        sha = Map.get(metadata, "sha") || Map.get(metadata, :sha)

        case validated_entry(ref, sha) do
          {:ok, ^identifier, validated} -> Map.put(acc, identifier, validated)
          _ -> acc
        end

      _invalid, acc ->
        acc
    end)
  end

  defp persist_if_changed(%{refs: refs} = state, refs), do: state

  defp persist_if_changed(state, refs) do
    JsonStore.write!(state.path, refs)
    %{state | refs: refs}
  rescue
    error ->
      Logger.warning("BranchRefStore persistence failed: path=#{state.path} reason=#{Exception.message(error)}")
      %{state | refs: refs}
  end

  defp log_load_failure(path, reason) do
    Logger.warning("BranchRefStore load failed: path=#{path} reason=#{inspect(reason)}")
    %{}
  end

  defp default_path do
    Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.branch_refs.json")
  end

  defp validated_refs(refs) do
    refs
    |> Enum.reduce(%{}, fn {ref, sha}, acc ->
      case validated_entry(ref, sha) do
        {:ok, identifier, metadata} -> Map.update(acc, identifier, metadata, fn _ -> :ambiguous end)
        :error -> acc
      end
    end)
    |> Map.reject(fn {_identifier, metadata} -> metadata == :ambiguous end)
  end

  defp validated_entry(ref, sha) do
    with true <- valid_sha?(sha),
         {:ticket, identifier, _topic} <- GithubKeys.ref_to_topic(ref) do
      {:ok, identifier, %{ref: ref, sha: String.downcase(sha)}}
    else
      _ -> :error
    end
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/i, sha)
end
