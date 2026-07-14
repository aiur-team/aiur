defmodule Aiur.GitHub.AgentCommentOrigins do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.GitHub.AgentCommentOrigins.{Command, Pending, Store}

  @max_origins_per_ticket 100
  @pending_key {__MODULE__, :pending_public_comment}

  @doc false
  @spec with_lock((-> term())) :: term() | {:error, term()}
  def with_lock(fun) when is_function(fun, 0) do
    with {:ok, path} <- path_for() do
      # Kept for compatibility with callers that do not know a ticket. New
      # provenance paths use `Store.with_ticket_lock/3` and never hold this
      # compatibility lock around shell or network work.
      marker = {__MODULE__, :compatibility_lock, path}
      :global.trans({marker, self()}, fun)
    end
  end

  @doc false
  @spec record_gh_pr_comment(String.t() | integer(), String.t(), String.t(), integer() | term()) ::
          :ok | :ignored | {:error, term()}
  def record_gh_pr_comment(ticket, command, output, _exit_code)
      when is_binary(command) and is_binary(output) do
    with :comment <- Command.classify(command),
         {:ok, comment_id} <- Command.comment_id(output) do
      Logger.info(
        "Recording agent-authored PR conversation comment: " <>
          "ticket=#{ticket} comment_id=#{comment_id}"
      )

      record_ids(ticket, [comment_id])
    else
      :ignored -> :ignored
      :unsupported_compound -> {:error, :unsupported_compound_public_comment_command}
      {:error, reason} -> log_missing_comment_identity(ticket, reason)
    end
  end

  def record_gh_pr_comment(_ticket, _command, _output, _exit_code), do: :ignored

  @doc false
  @spec begin_gh_pr_comment(String.t() | integer(), String.t(), String.t()) ::
          :ignored | :ok | {:error, term()}
  def begin_gh_pr_comment(ticket, command, operation_id)
      when is_binary(command) and is_binary(operation_id) and operation_id != "" do
    case Command.classify(command) do
      :comment -> begin_pending(ticket, operation_id, "gh_pr_comment", command)
      :unsupported_compound -> {:error, :unsupported_compound_public_comment_command}
      :ignored -> :ignored
    end
  end

  def begin_gh_pr_comment(_ticket, _command, _operation_id), do: :ignored

  @doc false
  @spec begin_review_thread_reply(String.t() | integer(), String.t()) :: :ok | {:error, term()}
  def begin_review_thread_reply(ticket, operation_id)
      when is_binary(operation_id) and operation_id != "" do
    begin_pending(ticket, operation_id, "review_thread_reply", nil)
  end

  def begin_review_thread_reply(_ticket, _operation_id), do: {:error, :invalid_operation_id}

  @doc false
  @spec complete_review_thread_reply(String.t() | integer(), String.t(), map()) ::
          :ok | {:error, term()}
  def complete_review_thread_reply(ticket, operation_id, comment) do
    complete_review_thread_reply(ticket, operation_id, comment, &record/2)
  end

  @spec complete_review_thread_reply(
          String.t() | integer(),
          String.t(),
          map(),
          (String.t() | integer(), map() -> :ok | {:error, term()})
        ) :: :ok | {:error, term()}
  def complete_review_thread_reply(ticket, operation_id, comment, recorder)
      when is_function(recorder, 2) and is_binary(operation_id) and is_map(comment) do
    case recorder.(ticket, comment) do
      :ok -> clear_pending(ticket, operation_id)
      {:error, _reason} = error -> remember_pending_comment(ticket, operation_id, comment, error)
      other -> remember_pending_comment(ticket, operation_id, comment, {:error, other})
    end
  end

  def complete_review_thread_reply(_ticket, _operation_id, _comment, _recorder),
    do: {:error, :invalid_verified_comment}

  @doc false
  @spec abandon_review_thread_reply(String.t() | integer(), String.t()) :: :ok | {:error, term()}
  def abandon_review_thread_reply(ticket, operation_id) when is_binary(operation_id) do
    clear_pending(ticket, operation_id)
  end

  def abandon_review_thread_reply(_ticket, _operation_id), do: {:error, :invalid_operation_id}

  @doc false
  @spec bind_gh_pr_comment_operation(String.t(), String.t(), String.t()) :: :ok | :ignored
  def bind_gh_pr_comment_operation(approved_operation_id, command, execution_operation_id)
      when is_binary(approved_operation_id) and is_binary(execution_operation_id) do
    pending = Process.get(pending_key(approved_operation_id)) || pending_by_command(command)

    case pending do
      %{} = pending ->
        Process.put(pending_key(execution_operation_id), pending)
        :ok

      nil ->
        :ignored
    end
  end

  def bind_gh_pr_comment_operation(_approved_operation_id, _command, _execution_operation_id), do: :ignored

  @doc false
  @spec complete_gh_pr_comment(
          String.t() | integer(),
          String.t() | nil,
          String.t() | nil,
          String.t(),
          integer() | term(),
          (String.t() | integer(), String.t(), String.t(), integer() | term() -> term())
        ) :: term()
  def complete_gh_pr_comment(ticket, operation_id, command, output, exit_code, recorder)
      when is_binary(output) and is_function(recorder, 4) do
    pending = pop_pending(operation_id) || durable_pending(ticket, operation_id)
    command = pending_command(pending, command)
    result = complete_comment(ticket, command, output, exit_code, recorder)

    case {pending, result} do
      {%{operation_id: pending_id}, result} when result in [:ok, :ignored] ->
        with :ok <- clear_pending(ticket, pending_id), do: result

      {%{} = pending, {:error, _reason} = error} ->
        error = retain_visible_pending_comment(ticket, pending, command, output, error)
        put_pending(operation_id || pending.operation_id, pending)
        error

      _other ->
        result
    end
  end

  @doc false
  @spec path_for() :: {:ok, Path.t()} | {:error, term()}
  def path_for do
    case Application.get_env(:aiur, :agent_comment_origins_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> stable_path_for()
    end
  end

  @doc false
  @spec record(String.t() | integer(), map()) :: :ok | {:error, term()}
  def record(ticket, verified_comment), do: record(ticket, verified_comment, [])

  @doc false
  @spec record(String.t() | integer(), map(), keyword()) :: :ok | {:error, term()}
  def record(ticket, verified_comment, _opts) when is_map(verified_comment) do
    with {:ok, comment_id} <- comment_id(verified_comment) do
      record_ids(ticket, [comment_id])
    end
  end

  def record(_ticket, _verified_comment, _opts), do: {:error, :invalid_verified_comment}

  @doc false
  @spec origin(String.t() | integer(), map()) :: {:ok, :agent | :external} | {:error, term()}
  def origin(ticket, comment) when is_map(comment) do
    with {:ok, path} <- path_for(),
         {:ok, ticket} <- normalize_ticket(ticket),
         {:ok, comment_id} <- comment_id(comment) do
      Store.with_ticket_lock(path, ticket, fn -> resolve_origin(path, ticket, comment_id) end)
    end
  rescue
    error -> {:error, {:origin_resolution_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:origin_resolution_failed, {kind, reason}}}
  end

  def origin(_ticket, _comment), do: {:error, :missing_comment_id}

  defp begin_pending(ticket, operation_id, kind, command) do
    with {:ok, path} <- path_for(),
         {:ok, ticket} <- normalize_ticket(ticket) do
      Store.with_ticket_lock(path, ticket, fn ->
        with {:ok, state} <- load_state(path, ticket) do
          if Enum.any?(state.pending, &(&1.operation_id == operation_id)) do
            {:error, :public_comment_operation_already_pending}
          else
            pending = Pending.new(operation_id, kind, command)

            with :ok <- write_state(path, ticket, %{state | pending: [pending | state.pending]}) do
              put_pending(operation_id, %{operation_id: operation_id, ticket: ticket, command: command})
              :ok
            end
          end
        end
      end)
    end
  rescue
    error -> {:error, {:persistence_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:persistence_failed, {kind, reason}}}
  end

  defp complete_comment(_ticket, nil, _output, _exit_code, _recorder), do: :ignored

  defp complete_comment(ticket, command, output, exit_code, recorder) do
    case recorder.(ticket, command, output, exit_code) do
      result when result in [:ok, :ignored] -> result
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_origin_recorder_result, other}}
    end
  end

  defp pending_command(%{command: command}, _fallback) when is_binary(command), do: command
  defp pending_command(_pending, command), do: command

  # A result can be visible even when the final recorder fails (for example a
  # local persistence fault after `gh` printed its comment URL). Retain its
  # exact identity in the durable pending operation so the poller still sees
  # this as agent-origin rather than trusted external feedback.
  defp retain_visible_pending_comment(ticket, pending, command, output, error) do
    with :comment <- Command.classify(command),
         {:ok, comment_id} <- Command.comment_id(output) do
      remember_pending_comment(ticket, pending.operation_id, %{"id" => comment_id}, error)
    else
      _other -> error
    end
  end

  defp resolve_origin(path, ticket, comment_id) do
    with {:ok, state} <- load_state(path, ticket),
         {:ok, state} <- recover_expired_pending(path, ticket, state) do
      cond do
        comment_id in state.origins ->
          {:ok, :agent}

        Enum.any?(state.pending, &(comment_id in &1.observed_ids)) ->
          {:ok, :agent}

        state.pending != [] ->
          Logger.warning(
            "Agent comment origin unresolved pending durable recovery: " <>
              "ticket=#{ticket} comment_id=#{comment_id} " <>
              "pending_operations=#{inspect(Enum.map(state.pending, & &1.operation_id))}"
          )

          {:error, {:pending_origin_recovery, Enum.map(state.pending, & &1.operation_id)}}

        true ->
          {:ok, :external}
      end
    end
  end

  defp recover_expired_pending(path, ticket, state) do
    {active, expired} = Pending.active_and_expired(state.pending)

    case expired do
      [] ->
        {:ok, state}

      _operations ->
        Logger.warning(
          "Recovering expired agent comment provenance operations: " <>
            "ticket=#{ticket} operation_ids=#{inspect(Enum.map(expired, & &1.operation_id))}"
        )

        recovered_origins =
          expired
          |> Enum.flat_map(& &1.observed_ids)
          |> Kernel.++(state.origins)
          |> Enum.uniq()
          |> Enum.take(@max_origins_per_ticket)

        recovered_state = %{state | origins: recovered_origins, pending: active}

        with :ok <- write_state(path, ticket, recovered_state) do
          {:ok, recovered_state}
        end
    end
  end

  defp record_ids(ticket, comment_ids) when is_list(comment_ids) do
    with {:ok, path} <- path_for(),
         {:ok, ticket} <- normalize_ticket(ticket) do
      Store.with_ticket_lock(path, ticket, fn ->
        with {:ok, state} <- load_state(path, ticket) do
          origins = (comment_ids ++ state.origins) |> Enum.uniq() |> Enum.take(@max_origins_per_ticket)
          write_state(path, ticket, %{state | origins: origins})
        end
      end)
    else
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:persistence_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:persistence_failed, {kind, reason}}}
  end

  defp clear_pending(ticket, operation_id) do
    with {:ok, path} <- path_for(),
         {:ok, ticket} <- normalize_ticket(ticket) do
      Store.with_ticket_lock(path, ticket, fn ->
        with {:ok, state} <- load_state(path, ticket) do
          pending = Enum.reject(state.pending, &(&1.operation_id == operation_id))
          write_state(path, ticket, %{state | pending: pending})
        end
      end)
    end
  rescue
    error -> {:error, {:persistence_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:persistence_failed, {kind, reason}}}
  end

  defp remember_pending_comment(ticket, operation_id, comment, error) do
    with {:ok, path} <- path_for(),
         {:ok, ticket} <- normalize_ticket(ticket),
         {:ok, comment_id} <- comment_id(comment) do
      Store.with_ticket_lock(path, ticket, fn ->
        with {:ok, state} <- load_state(path, ticket) do
          pending =
            Enum.map(state.pending, fn
              %{operation_id: ^operation_id} = operation ->
                %{operation | observed_ids: Enum.uniq([comment_id | operation.observed_ids])}

              operation ->
                operation
            end)

          with :ok <- write_state(path, ticket, %{state | pending: pending}) do
            error
          end
        end
      end)
    end
  rescue
    exception -> {:error, {:persistence_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:persistence_failed, {kind, reason}}}
  end

  defp load_state(path, ticket) do
    with {:ok, state} <- Store.read(path, ticket),
         {:ok, origins} <- normalize_origins(state_value(state, :origins, [])),
         {:ok, pending} <- Pending.normalize(state_value(state, :pending, [])) do
      {:ok,
       %{
         origins: origins,
         pending: pending
       }}
    end
  end

  defp write_state(path, ticket, %{origins: origins, pending: pending}) do
    Store.write(path, ticket, %{"origins" => origins, "pending" => pending})
  end

  defp normalize_origins(origins) when is_list(origins) do
    if Enum.all?(origins, &(is_binary(&1) and &1 != "")) do
      {:ok, origins |> Enum.uniq() |> Enum.take(@max_origins_per_ticket)}
    else
      {:error, :invalid_origins}
    end
  end

  defp normalize_origins(_origins), do: {:error, :invalid_origins}

  defp state_value(state, key, default) do
    case Map.fetch(state, key) do
      {:ok, value} -> value
      :error -> Map.get(state, Atom.to_string(key), default)
    end
  end

  defp put_pending(operation_id, pending), do: Process.put(pending_key(operation_id), pending)

  defp pop_pending(operation_id) when is_binary(operation_id) do
    key = pending_key(operation_id)
    pending = Process.get(key)
    Process.delete(key)
    pending
  end

  defp pop_pending(_operation_id), do: nil

  defp durable_pending(ticket, operation_id) when is_binary(operation_id) do
    with {:ok, path} <- path_for(),
         {:ok, ticket} <- normalize_ticket(ticket) do
      Store.with_ticket_lock(path, ticket, fn ->
        with {:ok, state} <- load_state(path, ticket) do
          Enum.find(state.pending, &(&1.operation_id == operation_id))
        end
      end)
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp durable_pending(_ticket, _operation_id), do: nil

  defp pending_key(operation_id), do: {@pending_key, operation_id}

  defp pending_by_command(command) when is_binary(command) do
    Process.get()
    |> Enum.find_value(fn
      {{@pending_key, _operation_id}, %{command: ^command} = pending} -> pending
      _entry -> nil
    end)
  end

  defp pending_by_command(_command), do: nil

  defp stable_path_for do
    with {:ok, state_dir} <- Paths.decision_state_dir() do
      {:ok, Path.join(state_dir, "agent-comment-origins.json")}
    end
  end

  defp log_missing_comment_identity(ticket, reason) do
    Logger.warning(
      "Agent PR comment completed without durable origin: " <>
        "ticket=#{inspect(ticket)} reason=#{inspect(reason)}"
    )

    {:error, reason}
  end

  defp normalize_ticket(ticket) when is_integer(ticket), do: {:ok, Integer.to_string(ticket)}

  defp normalize_ticket(ticket) when is_binary(ticket) do
    case String.trim(ticket) do
      "" -> {:error, :invalid_ticket}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_ticket(_ticket), do: {:error, :invalid_ticket}

  defp comment_id(comment) do
    case Map.get(comment, "id") || Map.get(comment, :id) do
      id when is_integer(id) ->
        {:ok, Integer.to_string(id)}

      id when is_binary(id) ->
        case String.trim(id) do
          "" -> {:error, :missing_comment_id}
          normalized -> {:ok, normalized}
        end

      _other ->
        {:error, :missing_comment_id}
    end
  end
end
