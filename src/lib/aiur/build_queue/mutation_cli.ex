defmodule Aiur.BuildQueue.MutationCLI do
  @moduledoc false
  alias Aiur.BuildQueue

  @spec run(keyword()) :: 0 | 1 | 64 | 124
  def run(opts) do
    case execute(opts) do
      {:ok, results} ->
        Enum.each(results, fn {id, result} -> IO.puts("#{id}: #{message(result)}") end)

        cond do
          Enum.any?(results, &match?({_, {:error, :outcome_unknown}}, &1)) -> 124
          Enum.all?(results, &match?({_, :ok}, &1)) -> 0
          true -> 1
        end

      {:error, reason} ->
        Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1)).("aiur: queue #{message({:error, reason})}")
        if reason in [:agent_workspace, :invalid_arguments], do: 64, else: 1
    end
  end

  @spec execute(keyword()) :: {:ok, [{String.t(), :ok | {:error, term()}}]} | {:error, term()}
  def execute(opts) do
    with :ok <- guard_workspace(opts), :ok <- validate(opts) do
      if opts[:build_order], do: adopt(opts), else: dispatch(Keyword.fetch!(opts, :verb), opts)
    end
  end

  defp guard_workspace(opts) do
    if Keyword.get(opts, :caller_agent_workspace, "") == "", do: :ok, else: {:error, :agent_workspace}
  end

  defp validate(opts) do
    ids = Keyword.get(opts, :ids, [])
    queue = opts[:queue]
    valid = is_list(ids) and Enum.all?(ids, &id?/1) and Enum.uniq(ids) == ids and (is_nil(queue) or (is_binary(queue) and String.trim(queue) != ""))
    valid = valid and valid_options?(opts) and valid_command?(opts[:verb], ids, opts)
    if valid, do: :ok, else: {:error, :invalid_arguments}
  end

  defp valid_options?(opts) do
    allowed =
      case opts[:verb] do
        :add -> [:ids, :queue, :after, :at, :build_order]
        :remove -> [:ids]
        :reorder -> [:ids, :to]
        verb when verb in [:hold, :release] -> [:ids, :queue]
        _ -> []
      end

    Enum.all?(Keyword.keys(opts), &(&1 in (allowed ++ [:verb, :caller_agent_workspace, :server, :error_fun])))
  end

  defp valid_command?(:add, ids, opts) do
    if opts[:build_order] do
      ids == [] and positive?(opts[:build_order]) and is_nil(opts[:after]) and is_nil(opts[:at])
    else
      ids != [] and valid_after?(opts[:after], ids) and (is_nil(opts[:at]) or position?(opts[:at]))
    end
  end

  defp valid_command?(:remove, ids, opts), do: ids != [] and is_nil(opts[:queue])
  defp valid_command?(:reorder, [_], opts), do: position?(opts[:to]) and is_nil(opts[:queue])
  defp valid_command?(verb, ids, opts) when verb in [:hold, :release], do: (length(ids) == 1 and is_nil(opts[:queue])) or (ids == [] and is_binary(opts[:queue]))
  defp valid_command?(_, _, _), do: false
  defp valid_after?(nil, _ids), do: true
  defp valid_after?(id, ids), do: id?(id) and id not in ids

  defp id?(id), do: is_binary(id) and Regex.match?(~r/\A[1-9][0-9]*\z/, id)
  defp position?(n), do: is_integer(n) and n >= 0
  defp positive?(n), do: is_integer(n) and n > 0

  defp adopt(opts) do
    root = opts[:build_order]
    result = call({:mutate, {:adopt, root, opts[:queue]}}, opts)

    results =
      case result do
        {:ok, refusals} -> [{"Build Order ##{root}", :ok} | Enum.map(refusals, fn {id, reason} -> {"##{id}", {:error, owning_queue(reason, id, opts)}} end)]
        error -> [{"Build Order ##{root}", error}]
      end

    {:ok, results}
  end

  defp dispatch(:add, opts) do
    {results, _} =
      Enum.map_reduce(opts[:ids], opts[:at], fn id, at ->
        options = Keyword.take(opts, [:after]) |> Keyword.put(:queue, opts[:queue] || "default")
        options = if is_nil(at), do: options, else: Keyword.put(options, :at, at)
        result = call({:mutate, {:add, [id], options}}, opts)
        {{"##{id}", result}, if(inserted?(result) and is_integer(at), do: at + 1, else: at)}
      end)

    {:ok, results}
  end

  defp dispatch(:remove, opts), do: {:ok, Enum.map(opts[:ids], &{"##{&1}", call({:mutate, {:remove, &1}}, opts)})}
  defp dispatch(:reorder, opts), do: {:ok, [{"##{hd(opts[:ids])}", call({:mutate, {:reorder, hd(opts[:ids]), opts[:to]}}, opts)}]}

  defp dispatch(verb, opts) do
    with {:ok, target} <- target(opts) do
      {:ok, [{opts[:queue] || "##{target}", call({verb, target}, opts)}]}
    end
  end

  defp inserted?(:ok), do: true
  defp inserted?({:error, {:marker_write_failed, _}}), do: true
  defp inserted?(_), do: false

  defp target(opts) do
    if opts[:queue] do
      model = BuildQueue.show(server(opts))
      select_queue(model, opts[:queue])
    else
      {:ok, hd(opts[:ids])}
    end
  end

  defp select_queue(%{status: status}, _name) when status not in [:running, :writes_paused], do: {:error, status}

  defp select_queue(model, name) do
    case Enum.find(model.queues, &(&1.name == name)) do
      nil -> {:error, :not_found}
      queue -> {:ok, queue.queue_id}
    end
  end

  defp owning_queue(:already_queued, id, opts) do
    model = BuildQueue.show(server(opts))
    queue = Enum.find(model.queues, fn queue -> Enum.any?(queue.items, &(&1.number == String.to_integer(id))) end)
    if queue, do: {:already_queued, queue.name}, else: :already_queued
  end

  defp owning_queue(reason, _, _), do: reason
  defp server(opts), do: Keyword.get(opts, :server, Aiur.BuildQueue.Server)

  defp call(command, opts) do
    GenServer.call(server(opts), command, 30_000)
  catch
    :exit, {:noproc, _} -> {:error, BuildQueue.show(server(opts)).status}
    :exit, {:timeout, _} -> {:error, :outcome_unknown}
  end

  defp message(:ok), do: "ok"
  defp message({:error, {:already_queued, name}}), do: "already in queue #{name}"
  defp message({:error, :agent_workspace}), do: "blocked in agent workspace"
  defp message({:error, :outcome_unknown}), do: "outcome unknown; run aiur queue show before retrying"
  defp message({:error, reason}) when is_atom(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")
  defp message({:error, reason}), do: inspect(reason)
end
