defmodule Aiur.Orchestrator.DeclaredBlockers do
  @moduledoc """
  Durable record of blocker links a worker declared with `aiur_declare_blocker`.

  A worker-declared link is advisory: it neither pauses the worker nor holds
  re-dispatch until the Executor confirms it (`aiur blocker confirm`). Planned
  links (build-order promotion or humans) never enter this store and keep
  gating dispatch. Each link is `declared`, `confirmed` or `dismissed`.
  """

  require Logger

  alias Aiur.{JsonStore, Signal}
  alias Aiur.Orchestrator.DependencyGate

  @file_name "declared-blockers.json"
  @advisory ["declared", "dismissed"]

  @type status :: String.t()

  @doc "Records a link after a successful `aiur_declare_blocker` admission and alerts the Executor once."
  @spec after_declare(term(), map(), term()) :: term()
  def after_declare({:ok, _} = result, issue, blocker) do
    if record(issue, blocker) == :recorded, do: alert(Map.get(issue, :identifier), blocker)
    result
  end

  def after_declare(result, _issue, _blocker), do: result

  @doc "Records a new worker-declared link, unless it is already known or a planned edge."
  @spec record(map(), term()) :: :recorded | :known | {:error, term()}
  def record(issue, blocker) do
    ticket = key(Map.get(issue, :identifier))

    if is_nil(ticket) or status(ticket, blocker) != nil or planned?(issue, blocker) do
      :known
    else
      with :ok <- put(ticket, blocker, "declared"), do: :recorded
    end
  end

  @doc "Whether a worker's dependency pause on this link should hold: a confirmed link or a planned one."
  @spec hold?(map(), term()) :: boolean()
  def hold?(issue, blocker) do
    case status(Map.get(issue, :identifier), blocker) do
      nil -> planned?(issue, blocker)
      status -> status == "confirmed"
    end
  end

  @doc "Forgets a link once `aiur_unblock` removed it."
  @spec after_unblock(term(), map(), term()) :: term()
  def after_unblock(result, issue, blocker) do
    if result == :ok or match?({:ok, _}, result), do: forget(issue, blocker)
    result
  end

  @spec forget(map(), term()) :: :ok | {:error, term()}
  def forget(issue, blocker) do
    case key(Map.get(issue, :identifier)) do
      nil -> :ok
      ticket -> update(&drop(&1, ticket, key(blocker)))
    end
  end

  @spec status(term(), term()) :: status() | nil
  def status(ticket, blocker), do: get_in(read(), [key(ticket), key(blocker)])

  @doc "Unconfirmed worker-declared blockers of `ticket`; dispatch treats them as satisfied."
  @spec advisory(term()) :: MapSet.t(String.t())
  def advisory(ticket) do
    for {blocker, status} <- Map.get(read(), key(ticket), %{}), status in @advisory, into: MapSet.new(), do: blocker
  end

  @doc "Executor verdict on a declared link: `confirmed` holds it like a planned link, `dismissed` keeps it advisory and silent."
  @spec set_verdict(term(), term(), :confirm | :dismiss) :: :ok | {:error, term()}
  def set_verdict(ticket, blocker, verdict) when verdict in [:confirm, :dismiss] do
    case status(ticket, blocker) do
      nil -> {:error, :not_declared}
      _ -> put(key(ticket), blocker, if(verdict == :confirm, do: "confirmed", else: "dismissed"))
    end
  end

  @doc "Raises the needs-attention Executor alert naming the declared link."
  @spec alert(term(), term()) :: :ok
  def alert(ticket, blocker) do
    {ticket, blocker} = {key(ticket), key(blocker)}

    _ =
      Signal.alert("ticket.#{ticket}.dependency.declared_blocker",
        issue: ticket,
        message: "##{ticket} declared ##{blocker} as a blocker; confirm to hold ##{ticket} until ##{blocker} merges",
        reason: "Advisory until confirmed: `aiur blocker confirm #{ticket} #{blocker}` pauses ##{ticket} and holds it; `aiur blocker dismiss #{ticket} #{blocker}` keeps it running.",
        needs_attention: true,
        severity: "warning"
      )

    :ok
  end

  defp planned?(issue, blocker) do
    issue
    |> DependencyGate.cached_issue()
    |> Map.get(:blocked_by, [])
    |> List.wrap()
    |> Enum.any?(&(key(Map.get(&1, :identifier) || Map.get(&1, :id)) == key(blocker)))
  rescue
    _ -> false
  end

  defp put(ticket, blocker, status), do: update(&Map.update(&1, key(ticket), %{key(blocker) => status}, fn row -> Map.put(row, key(blocker), status) end))

  defp drop(links, ticket, blocker) do
    row = links |> Map.get(ticket, %{}) |> Map.delete(blocker)
    if row == %{}, do: Map.delete(links, ticket), else: Map.put(links, ticket, row)
  end

  defp update(fun) do
    with {:ok, path} <- path() do
      :global.trans({__MODULE__, path}, fn -> JsonStore.write(path, fun.(read())) end)
    end
  rescue
    error -> {:error, error}
  end

  defp read do
    with {:ok, path} <- path(), {:ok, %{} = links} <- JsonStore.read(path, %{}) do
      links
    else
      other ->
        Logger.warning("declared blocker store unreadable: #{inspect(other)}")
        %{}
    end
  end

  defp path do
    case Application.get_env(:aiur, :declared_blockers_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> with {:ok, root} <- Aiur.Project.state_dir(), do: {:ok, Path.join(root, @file_name)}
    end
  end

  defp key(nil), do: nil
  defp key(value), do: value |> to_string() |> String.trim_leading("#")
end
