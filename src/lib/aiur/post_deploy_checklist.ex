defmodule Aiur.PostDeployChecklist do
  @moduledoc "Durable checklist of manual checks reported by merged pull requests."

  use GenServer
  require Logger

  alias Aiur.{Config, JsonStore}
  alias Aiur.Events
  alias Aiur.Events.Exchange

  @filename "post_deploy_checks.json"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec ingest(map(), GenServer.server()) :: :ok | {:error, term()}
  def ingest(event, server \\ __MODULE__) when is_map(event), do: GenServer.call(server, {:ingest, event})

  @spec list(GenServer.server()) :: [map()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @spec status(GenServer.server()) :: :ok | {:error, term()}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec mark_done(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def mark_done(id, actor, server \\ __MODULE__) when is_binary(id) and is_binary(actor),
    do: GenServer.call(server, {:mark_done, id, actor})

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || state_path()
    exchange = Keyword.get(opts, :exchange, Exchange)

    if Keyword.get(opts, :subscribe?, true), do: :ok = Events.subscribe("ticket.*.pr.merged", exchange)

    with path when is_binary(path) <- path,
         {:ok, records} when is_list(records) <- JsonStore.read(path, []),
         true <- Enum.all?(records, &valid_record?/1) do
      {:ok, %{path: path, records: records, writable?: true}}
    else
      {:error, reason} -> {:ok, %{path: nil, records: [], writable?: false, error: reason}}
      _ -> {:ok, %{path: nil, records: [], writable?: false, error: :invalid_checklist}}
    end
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, Enum.reverse(state.records), state}
  def handle_call(:status, _from, %{writable?: true} = state), do: {:reply, :ok, state}
  def handle_call(:status, _from, state), do: {:reply, {:error, Map.get(state, :error, :store_unavailable)}, state}

  def handle_call({:ingest, _event}, _from, %{writable?: false} = state), do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:ingest, event}, _from, state) do
    case checks(event) do
      [] ->
        {:reply, :ok, state}

      entries ->
        {next, changed?} = Enum.reduce(entries, {state.records, false}, &upsert(&1, &2, event))

        case persist(next, state, changed?) do
          {:ok, next_state} -> {:reply, :ok, next_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:mark_done, _id, _actor}, _from, %{writable?: false} = state), do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:mark_done, id, actor}, _from, state) do
    case Enum.find(state.records, &(&1["id"] == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{"done_at" => done_at} = _item when is_binary(done_at) ->
        {:reply, :ok, state}

      item ->
        at = DateTime.utc_now() |> DateTime.to_iso8601()
        updated = Map.merge(item, %{"done_at" => at, "done_by" => actor})
        next = [updated | Enum.reject(state.records, &(&1["id"] == id))]

        case persist(next, state, true) do
          {:ok, next_state} -> {:reply, :ok, next_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info({:event, %{topic: topic} = event}, state) when is_binary(topic) do
    case checks(event) do
      [] ->
        {:noreply, state}

      entries ->
        {next, changed?} = Enum.reduce(entries, {state.records, false}, &upsert(&1, &2, event))

        case persist(next, state, changed?) do
          {:ok, next_state} ->
            {:noreply, next_state}

          {:error, reason} ->
            Logger.error("aiur_post_deploy_checklist ingest_failed pr=#{inspect(get_in(event, [:pr, "number"]))} reason=#{inspect(reason)}")
            {:noreply, state}
        end
    end
  rescue
    error ->
      Logger.error("aiur_post_deploy_checklist ingest_failed pr=#{inspect(get_in(event, [:pr, "number"]))} error=#{Exception.message(error)}")
      {:noreply, state}
  end

  defp persist(_records, state, false), do: {:ok, state}

  defp persist(records, state, true) do
    :ok = JsonStore.write!(state.path, records)
    next_state = %{state | records: records}
    broadcast(next_state.records)
    {:ok, next_state}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp upsert(entry, {records, changed?}, event) do
    pr = Map.get(event, :pr, %{})

    repo =
      Map.get(event, :repository) || get_in(pr, ["base", "repo", "full_name"]) ||
        get_in(pr, ["head", "repo", "full_name"]) || "unknown/unknown"

    id = "#{repo}##{Map.get(pr, "number", "unknown")}:#{entry.text}"

    case Enum.find_index(records, &(&1["id"] == id)) do
      nil ->
        item = %{
          "id" => id,
          "repository" => repo,
          "pr_number" => Map.get(pr, "number"),
          "pr_url" => safe_pr_url(repo, Map.get(pr, "number")),
          "pr_author" => get_in(pr, ["user", "login"]),
          "ticket" => ticket_id(event),
          "text" => entry.text,
          "operator" => entry.operator,
          "merged_at" => Map.get(pr, "merged_at"),
          "done_at" => nil,
          "done_by" => nil
        }

        {[item | records], true}

      _ ->
        {records, changed?}
    end
  end

  defp checks(%{post_deploy_checks: checks}) when is_list(checks), do: Enum.filter(checks, &is_binary/1) |> Enum.map(&parse_check/1)
  defp checks(_event), do: []

  defp parse_check(text) do
    case Regex.run(~r/\s*\(operator:\s*([^\)]+)\)\s*$/i, text) do
      [_, operator] -> %{text: String.trim(String.replace(text, ~r/\s*\(operator:\s*[^\)]+\)\s*$/i, "")), operator: String.trim(operator)}
      _ -> %{text: String.trim(text), operator: nil}
    end
  end

  defp ticket_id(%{topic: topic}) when is_binary(topic) do
    case Regex.run(~r/^ticket\.([^.]+)\.pr\.merged$/, topic) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp ticket_id(_), do: nil

  defp safe_pr_url(repo, number) when is_binary(repo) and is_integer(number) and number > 0 do
    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repo), do: "https://github.com/#{repo}/pull/#{number}"
  end

  defp safe_pr_url(_repo, _number), do: nil

  defp valid_record?(%{"id" => id, "text" => text, "done_at" => done_at}) when is_binary(id) and is_binary(text) and (is_binary(done_at) or is_nil(done_at)), do: true
  defp valid_record?(_record), do: false

  defp broadcast(records) do
    Phoenix.PubSub.broadcast(Aiur.PubSub, "post_deploy_checks", {:post_deploy_checks_updated, Enum.reverse(records)})
  rescue
    _error -> :ok
  end

  defp state_path do
    with {:ok, dir} <- Config.Paths.decision_state_dir(), do: Path.join(dir, @filename)
  end
end
