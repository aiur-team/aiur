defmodule Aiur.Experiments.Auto.FeaturePoll do
  @moduledoc false
  alias Aiur.Experiments.Auto.{EpicMembers, FeatureEpics, FeatureExperiment, FeatureState}

  @spec run(keyword(), boolean()) :: {:ok, map()} | {:error, term()}
  def run(opts, refresh?) do
    path = Keyword.fetch!(opts, :path)
    config = Keyword.fetch!(opts, :config)
    now = Keyword.get(opts, :clock, &DateTime.utc_now/0).()
    repo = Keyword.get(opts, :managed_repo, Aiur.Experiments.Paths.repo())

    with {:ok, data} <- Aiur.JsonStore.read(path, %{"epics" => %{}, "labelled" => [], "discovered_at" => 0}),
         {:ok, data} <- discovery(data, repo, config, now, opts),
         :ok <- persist(path, data) do
      labels = Map.merge(Map.new(data["labelled"], &{to_string(&1), true}), FeatureEpics.labels(repo, config.feature_label, data["discovered_at"]))
      numbers = Enum.uniq(Map.keys(data["epics"]) ++ for({id, true} <- labels, do: id))
      Enum.reduce_while(numbers, {:ok, data}, &poll_one(&1, &2, labels, repo, config, now, opts, refresh?))
    end
  end

  defp discovery(data, repo, config, now, opts) do
    if DateTime.to_unix(now) - data["discovered_at"] >= 3_600 do
      with {:ok, numbers} <- FeatureEpics.discover(repo, config.feature_label, opts) do
        {:ok, Map.merge(data, %{"labelled" => numbers, "discovered_at" => DateTime.to_unix(now)})}
      end
    else
      {:ok, data}
    end
  end

  defp poll_one(number, {:ok, data}, labels, repo, config, now, opts, refresh?) do
    record = data["epics"][number] || %{"state" => nil, "checked_at" => 0, "pending" => []}

    with {:ok, record} <- effects(number, record, config, now, opts),
         {:ok, observation, checked_at} <- observation(number, record, Map.get(labels, number, false), repo, now, opts, refresh?),
         {state, actions} <- FeatureState.transition(record["state"], observation, config, now),
         record = Map.merge(record, %{"state" => state, "pending" => Enum.map(actions, &Atom.to_string/1), "observation" => observation, "checked_at" => checked_at}),
         pending = put_in(data, ["epics", number], record),
         :ok <- persist(Keyword.fetch!(opts, :path), pending),
         {:ok, record} <- effects(number, record, config, now, opts),
         updated = put_in(pending, ["epics", number], record),
         :ok <- persist(Keyword.fetch!(opts, :path), updated) do
      {:cont, {:ok, updated}}
    else
      error -> {:halt, error}
    end
  end

  defp observation(_number, %{"state" => %{"phase" => "cancelled"}} = record, labelled?, _repo, _now, _opts, _refresh?) do
    {:ok, Map.put(record["observation"], "labelled", labelled?), record["checked_at"]}
  end

  defp observation(number, record, labelled?, repo, now, opts, refresh?) do
    seconds = DateTime.to_unix(now)
    held = EpicMembers.held(repo, String.to_integer(number)) |> Enum.sort()
    known = for member <- get_in(record, ["observation", "members"]) || [], do: member["number"]
    changed? = held != [] and held != Enum.sort(known)
    due? = seconds - record["checked_at"] >= 3_600 or ((refresh? or changed?) and seconds - record["checked_at"] >= 300)

    if due? or is_nil(record["observation"]) do
      with {:ok, observation} <- EpicMembers.read(repo, String.to_integer(number), opts), do: {:ok, Map.put(observation, "labelled", labelled?), seconds}
    else
      {:ok, Map.put(record["observation"], "labelled", labelled?), record["checked_at"]}
    end
  end

  defp effects(number, record, config, now, opts) do
    Enum.reduce_while(record["pending"], {:ok, record}, fn action, {:ok, record} ->
      case FeatureExperiment.apply_effect(number, record["state"], action(action), config, now, opts) do
        {:ok, state} -> {:cont, {:ok, %{record | "state" => state, "pending" => List.delete(record["pending"], action)}}}
        error -> {:halt, error}
      end
    end)
  end

  defp action("scope"), do: :scope
  defp action("arm"), do: :arm
  defp action("freeze"), do: :freeze
  defp action("cancel"), do: :cancel
  defp action("resolve_live"), do: :resolve_live

  defp persist(path, data) do
    with :ok <- Aiur.Journal.ensure_directory(Path.dirname(path)), do: Aiur.Fs.atomic_write(path, Jason.encode!(data), fsync: true, mode: 0o600)
  end
end
