defmodule AiurWeb.StreamdeckChannel.CommandAnswers do
  @moduledoc """
  The focused agent's Commands for `AiurWeb.StreamdeckChannel`: projecting the
  history page, enforcing that a device answers only the Command it is focused
  on at the version it read, and recording that answer as the operator's.
  """

  alias Aiur.Commands
  alias AiurWeb.{Endpoint, StreamdeckCommands}

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

  # The device may only answer a Command that belongs to the agent it is
  # currently focused on, and only the exact version it read. Fetching the
  # decision here both enforces the boundary and lets the store's replay
  # semantics decide duplicate-versus-conflict for a retried answer.
  @spec validate_focused_command(Phoenix.Socket.t(), String.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def validate_focused_command(socket, decision_id, identifier, version) do
    case StreamdeckCommands.detail(decision_id, store: command_store(socket)) do
      {:ok, item} ->
        cond do
          get_in(item, ["ticket", "identifier"]) != identifier ->
            {:error, :command_not_focused}

          Map.get(item, "version") != version ->
            {:error, {:stale_version, version, Map.get(item, "version")}}

          # Only open and deferred Commands are answerable, allowlisted rather
          # than blocklisted: every newly-added terminal status would otherwise
          # silently become answerable the moment it exists. The TS client
          # renders the same two statuses as answerable (`commands.ts`), so
          # client and server agree on what "answerable" means.
          Map.get(item, "status") not in ["open", "deferred"] ->
            {:error, {:not_answerable, Map.get(item, "status")}}

          true ->
            :ok
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec record_command_answer(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def record_command_answer(decision_id, answer) do
    store = command_store()
    actor = StreamdeckCommands.actor()

    # `store` is the decision server — a module or a pid — so the answer must
    # go through `Aiur.DecisionStore.answer/5` with the server passed as the
    # fourth argument, exactly as the dashboard's decision commands do. Calling
    # `store.answer/4` would `apply/3` a pid as a module and fail.
    case Commands.answer(decision_id, answer, [actor: actor], store) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:answer_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  @spec answer_result(term()) :: term()
  def answer_result(%{status: status, decision: decision}) do
    %{"status" => Atom.to_string(status), "decision" => StreamdeckCommands.item(decision)}
  end

  def answer_result(result), do: result

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
  def command_store, do: Endpoint.config(:decision_store) || Commands.default_store()
end
