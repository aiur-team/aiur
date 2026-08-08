defmodule Aiur.OpenAICompat.Checkpoint do
  @moduledoc false

  @spec deliver(map(), map(), keyword()) :: {:delivered | :noop, map()}
  def deliver(state, checkpoint, opts) do
    callback = Keyword.get(opts, :on_safe_checkpoint, fn _checkpoint -> :noop end)

    case callback.(checkpoint) do
      :noop ->
        {:noop, state}

      {:deliver_text, text, on_success, _on_failure}
      when is_binary(text) and is_function(on_success, 1) ->
        request_id = state.next_request_id

        on_success.(metadata(state, checkpoint, request_id))

        {:delivered,
         %{
           state
           | next_request_id: request_id + 1,
             messages: state.messages ++ [%{"role" => "user", "content" => text}]
         }}

      {:deliver_text, _text, _on_success, on_failure} when is_function(on_failure, 1) ->
        on_failure.(:invalid_operator_message)
        {:noop, state}

      _other ->
        {:noop, state}
    end
  rescue
    error ->
      notify_error(opts, error)
      {:noop, state}
  end

  @spec defer(map(), map(), [map()], keyword()) :: {map(), [map()]}
  def defer(state, checkpoint, deliveries, opts) do
    callback = Keyword.get(opts, :on_safe_checkpoint, fn _checkpoint -> :noop end)

    case callback.(checkpoint) do
      {:deliver_text, text, on_success, _on_failure}
      when is_binary(text) and is_function(on_success, 1) ->
        request_id = state.next_request_id
        delivery = %{text: text, on_success: on_success, metadata: metadata(state, checkpoint, request_id)}
        {%{state | next_request_id: request_id + 1}, deliveries ++ [delivery]}

      {:deliver_text, _text, _on_success, on_failure} when is_function(on_failure, 1) ->
        on_failure.(:invalid_operator_message)
        {state, deliveries}

      _other ->
        {state, deliveries}
    end
  rescue
    error ->
      notify_error(opts, error)
      {state, deliveries}
  end

  @spec flush(map(), [map()], keyword()) :: map()
  def flush(state, deliveries, opts) do
    Enum.reduce(deliveries, state, fn delivery, current ->
      try do
        delivery.on_success.(delivery.metadata)

        %{
          current
          | messages: current.messages ++ [%{"role" => "user", "content" => delivery.text}]
        }
      rescue
        error ->
          notify_error(opts, error)
          current
      end
    end)
  end

  defp metadata(state, checkpoint, request_id) do
    %{
      backend: state.config.backend,
      checkpoint: checkpoint.kind,
      request_id: request_id,
      turn_id: "openai-compat-#{request_id}"
    }
  end

  defp notify_error(opts, error) do
    case Keyword.get(opts, :on_checkpoint_error) do
      fun when is_function(fun, 1) -> fun.(error)
      _other -> :ok
    end
  end
end
