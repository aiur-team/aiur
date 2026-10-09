defmodule Aiur.BuildQueue.Writer do
  @moduledoc "Serial label writes with durable intents and a rolling minute write budget."
  require Logger
  alias Aiur.BuildQueue.{Attention, WriteEvidence, WriteProtocol}
  alias Aiur.BuildQueue.Model.Latch

  @spec new() :: map()
  def new, do: %{writes: [], failures: %{}, ensured?: false, paused?: false}

  @spec run(map(), list(), map()) :: map()
  def run(context, actions, runtime) do
    context = Map.merge(context, %{writer: runtime, status: if(runtime.paused?, do: :writes_paused, else: :running), promoted: [], write_attentions: [], write_results: []})
    context = Enum.reduce_while(actions, context, &execute/2)
    promoted = Enum.reverse(context.promoted)
    if promoted != [], do: context.claim_probe.notify_demand(promoted)
    context
  end

  defp execute({action, id}, context) when action in [:promote, :mark, :unmark] do
    context = retry(context, action, id, [1_000, 4_000, 16_000])
    if context.status == :running, do: {:cont, context}, else: {:halt, context}
  end

  defp execute({action, {:promoted_unauthorized, id}}, context) when action in [:attention_open, :attention_resolve] do
    result = if action == :attention_open, do: Attention.open(:promoted_unauthorized, id, %{ticket: id}), else: Attention.resolve(:promoted_unauthorized, id)

    case context.store.load() do
      {:ok, document} ->
        if result != :ok, do: Logger.warning("Build queue unauthorized attention failed issue_id=#{id} issue_identifier=##{id} action=#{action}: #{inspect(result)}")
        {:cont, %{context | document: document}}

      {:error, _reason} ->
        {:halt, %{context | status: :store_unavailable}}
    end
  end

  defp execute(_action, context), do: {:cont, context}

  defp retry(context, action, id, delays) do
    if action == :promote and not WriteEvidence.fresh?(context, id), do: record(context, action, id, {:error, :stale_observation}), else: attempt(context, action, id, delays)
  end

  defp attempt(context, action, id, delays) do
    case prepare(context, action) do
      {:wait, context} ->
        record(context, action, id, {:error, :paced})

      {:error, context, result} ->
        context |> record(action, id, result) |> outcome(action, id, result, delays)

      {:ok, context} ->
        {context, result} = WriteProtocol.attempt(context, action, id, context.writer)
        context |> record(action, id, result) |> outcome(action, id, result, delays)
    end
  end

  defp record(context, action, id, result), do: %{context | write_results: context.write_results ++ [{action, id, result}]}

  defp prepare(context, :mark) when not context.writer.ensured? do
    case reserve(context) do
      {:wait, context} -> {:wait, context}
      {:ok, context} -> ensure(context)
    end
  end

  defp prepare(context, _action), do: reserve(context)

  defp ensure(context) do
    case context.tracker.ensure_labels([context.marker]) do
      :ok -> prepare(%{context | writer: %{context.writer | ensured?: true}}, :mark)
      result -> {:error, context, result}
    end
  end

  defp reserve(context) do
    now = context.clock.()
    writes = Enum.filter(context.writer.writes, &(now - &1 < 60_000))
    writer = %{context.writer | writes: writes}

    if length(writes) < context.max_writes do
      {:ok, %{context | writer: %{writer | writes: writes ++ [now]}}}
    else
      {:wait, %{context | writer: writer, status: :paced}}
    end
  end

  defp outcome(%{status: :store_unavailable} = context, _action, _id, _result, _delays), do: context

  defp outcome(context, action, id, result, delays) do
    case WriteProtocol.classify(result) do
      :ok -> success(context, action, id)
      :reobserve -> context
      :paused -> %{context | status: :writes_paused, writer: %{context.writer | paused?: true}}
      :retry -> failed(context, action, id, delays)
    end
  end

  defp success(context, action, id) do
    writer = %{context.writer | failures: Map.delete(context.writer.failures, id), paused?: false}
    promoted = if action == :promote, do: [id | context.promoted], else: context.promoted
    %{context | writer: writer, promoted: promoted, status: :running}
  end

  defp failed(context, action, id, delays) do
    count = Map.get(context.writer.failures, id, 0) + 1
    context = %{context | writer: %{context.writer | failures: Map.put(context.writer.failures, id, count)}}
    context = if count >= 5, do: latch(context, id), else: context
    again(context, action, id, delays)
  end

  defp again(%{status: :store_unavailable} = context, _action, _id, _delays), do: context
  defp again(context, _action, _id, []), do: context

  defp again(context, action, id, [delay | rest]) do
    context.sleep.(delay)
    retry(context, action, id, rest)
  end

  defp latch(context, id) do
    key = {:write_failed, id}
    if Enum.any?(context.document.latches, &(&1.key == key)), do: context, else: save_latch(context, key)
  end

  defp save_latch(context, key) do
    latch = %Latch{key: key, opened_at_ms: context.clock.()}
    document = %{context.document | latches: context.document.latches ++ [latch]}

    case context.store.save(document) do
      :ok -> %{context | document: document, write_attentions: context.write_attentions ++ [{:attention_open, key}]}
      {:error, _reason} -> %{context | status: :store_unavailable}
    end
  end
end
