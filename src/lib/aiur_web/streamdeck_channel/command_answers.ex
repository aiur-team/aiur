defmodule AiurWeb.StreamdeckChannel.CommandAnswers do
  @moduledoc """
  The focused agent's Commands for `AiurWeb.StreamdeckChannel`: projecting the
  history page, enforcing the focused-ticket boundary, and submitting versioned
  operator answers through the shared answer facade.
  """

  alias Aiur.Commands
  alias Aiur.Commands.Answering
  alias AiurWeb.{EndpointConfig, StreamdeckCommands}

  # The focused agent's Commands page. An unreadable store is projected as
  # explicitly unavailable rather than as an empty history, so the device says
  # "Commands unavailable" instead of silently showing no Commands for an agent
  # that has them. It reads through the same endpoint-configured store as the
  # interactive `commands_page`/`answer_command` handlers, so a configured
  # (or injected) store is honoured on the focus push too.
  @spec commands_projection(String.t()) :: map()
  def commands_projection(identifier) do
    case StreamdeckCommands.history(identifier, nil, store: command_store()) do
      {:ok, page} -> Map.put(page, "identifier", identifier)
      {:error, _reason} -> %{"identifier" => identifier, "unavailable" => true}
    end
  end

  # A `decision_changed` broadcast carries only the decision id; the focused
  # Command surface must be refreshed only when that decision belongs to the
  # agent being watched, so the device is not repainted for every Command in
  # the fleet. On an error the page repaints anyway (fail-open): skipping a
  # repaint would silently freeze a stale Commands page with no later event to
  # refresh it, while `commands_projection/1` already surfaces an unreadable
  # store as an explicit "unavailable" page.
  @spec focused_command?(Phoenix.Socket.t(), String.t(), String.t()) :: boolean()
  def focused_command?(socket, decision_id, identifier) do
    case StreamdeckCommands.detail(decision_id, store: command_store(socket)) do
      {:ok, item} -> get_in(item, ["ticket", "identifier"]) == identifier
      {:error, _reason} -> true
    end
  rescue
    _error -> true
  catch
    _kind, _reason -> true
  end

  # Check ticket ownership here; the answer facade/store owns version and
  # lifecycle checks so completed Commands can return a winner or a replay.
  @spec validate_focused_command(Phoenix.Socket.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def validate_focused_command(socket, decision_id, identifier) do
    case StreamdeckCommands.detail(decision_id, store: command_store(socket)) do
      {:ok, item} ->
        if get_in(item, ["ticket", "identifier"]) == identifier,
          do: :ok,
          else: {:error, :command_not_focused}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec record_command_answer(String.t(), map()) :: {:ok, map()} | {:error, map()}
  def record_command_answer(decision_id, answer) do
    decision_id
    |> Answering.answer(answer, actor: StreamdeckCommands.actor(), actor_source: :streamdeck, client: %{surface: :streamdeck}, store: command_store())
    |> StreamdeckCommands.answer_reply()
  end

  # Exactly one of option_id or custom_response, mirroring the CLI's
  # `executor-answer --option|--custom-response` contract so the custom-response
  # path maps onto an already-supported operation.
  @spec build_answer_payload(map()) :: {:ok, map()} | {:error, atom()}
  def build_answer_payload(%{"option_id" => option_id, "version" => version, "idempotency_key" => key})
      when is_binary(option_id) and option_id != "" do
    {:ok, %{"idempotency_key" => key, "expected_version" => version, "option_id" => option_id}}
  end

  def build_answer_payload(%{"custom_response" => text, "version" => version, "idempotency_key" => key})
      when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty_custom_response}
      text -> {:ok, %{"idempotency_key" => key, "expected_version" => version, "custom_response" => text}}
    end
  end

  def build_answer_payload(_payload), do: {:error, :invalid_answer}

  @spec command_store(term()) :: term()
  def command_store(_socket), do: command_store()

  @spec command_store() :: term()
  def command_store, do: EndpointConfig.get(:decision_store) || Commands.default_store()
end
