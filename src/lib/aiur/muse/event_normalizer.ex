defmodule Aiur.Muse.EventNormalizer do
  @moduledoc "Maps native Muse usage into shared agent accounting without changing its raw payload."

  alias Aiur.Muse.Usage

  @spec normalize_event(map()) :: map()
  def normalize_event(%{payload: %{"method" => "session/tokenUsage"} = payload} = event) do
    case Usage.token_notification(payload) do
      {:ok, %{session_id: session_id, stream: %{id: stream_id, kind: "session"}, cumulative: cumulative}} ->
        if session_id == event[:muse_session_id] do
          event
          |> Map.put(:accounting_usage, %{
            input_tokens: cumulative.input,
            output_tokens: cumulative.output,
            total_tokens: cumulative.total
          })
          |> Map.put(:usage_epoch, {session_id, stream_id})
        else
          event
        end

      _ ->
        event
    end
  end

  def normalize_event(%{payload: %{"method" => "session/contextUsage"} = payload} = event) do
    case Usage.context_notification(payload) do
      {:ok, %{session_id: session_id} = context} ->
        if session_id == event[:muse_session_id], do: Map.put(event, :context_usage, context), else: event

      _ ->
        event
    end
  end

  def normalize_event(%{payload: %{"method" => "turn/completed"}} = event),
    do: Map.put(event, :usage_source, :cumulative_only)

  def normalize_event(event) when is_map(event), do: event
end
