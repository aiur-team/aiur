defmodule Aiur.GitHub.AgentCommentOrigins do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @max_origins_per_ticket 100

  @type pending_public_comment :: %{
          path: Path.t(),
          ticket: String.t(),
          command: String.t(),
          operation_id: String.t(),
          lock_marker: term()
        }

  @doc false
  @spec with_lock((-> term())) :: term() | {:error, term()}
  def with_lock(fun) when is_function(fun, 0) do
    with {:ok, path} <- path_for() do
      with_lock(path, fun)
    end
  end

  @doc false
  @spec record_gh_pr_comment(String.t() | integer(), String.t(), String.t(), integer() | term()) ::
          :ok | :ignored | {:error, term()}
  def record_gh_pr_comment(ticket, command, output, exit_code)
      when is_binary(command) and is_binary(output) and exit_code == 0 do
    with true <- agent_comment_command?(command),
         {:ok, comment_id} <- gh_comment_id_from_output(output) do
      Logger.info("Recording agent-authored PR conversation comment: ticket=#{ticket} comment_id=#{comment_id}")
      record(ticket, %{"id" => comment_id})
    else
      false ->
        :ignored

      {:error, reason} ->
        Logger.warning(
          "Agent PR comment completed without durable origin: " <>
            "ticket=#{inspect(ticket)} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  def record_gh_pr_comment(_ticket, _command, _output, _exit_code), do: :ignored

  @doc false
  @spec begin_gh_pr_comment(String.t() | integer(), String.t(), String.t()) ::
          :ignored | :ok | {:error, term()}
  def begin_gh_pr_comment(ticket, command, operation_id)
      when is_binary(command) and is_binary(operation_id) and operation_id != "" do
    with true <- agent_comment_command?(command),
         {:ok, path} <- path_for(),
         {:ok, ticket} <- normalize_ticket(ticket) do
      begin_public_comment_lock(ticket, command, operation_id, path)
    else
      false -> :ignored
      {:error, reason} -> {:error, reason}
    end
  end

  def begin_gh_pr_comment(_ticket, _command, _operation_id), do: :ignored

  @doc false
  @spec bind_gh_pr_comment_operation(String.t(), String.t(), String.t()) :: :ok | :ignored
  def bind_gh_pr_comment_operation(approved_operation_id, command, execution_operation_id)
      when is_binary(approved_operation_id) and is_binary(command) and is_binary(execution_operation_id) do
    case pop_pending_public_comment(approved_operation_id, nil) do
      %{} = pending ->
        put_pending_public_comment(pending)
        :ok

      nil ->
        case pop_pending_public_comment(execution_operation_id, command) do
          %{} = pending ->
            put_pending_public_comment(pending)
            :ok

          nil ->
            :ignored
        end
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
    case pop_pending_public_comment(operation_id, command) do
      %{} = pending ->
        result = recorder.(ticket, pending.command, output, exit_code)

        case finalize_pending_public_comment(pending, result) do
          :ok -> result
          {:error, _reason} = error -> error
        end

      nil when is_binary(command) ->
        recorder.(ticket, command, output, exit_code)

      nil ->
        :ignored
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

  defp with_lock(path, fun) do
    lock_marker = {__MODULE__, path}

    if Process.get(lock_marker) == true do
      fun.()
    else
      :global.trans({lock_marker, self()}, fn ->
        previous = Process.get(lock_marker, :unset)
        Process.put(lock_marker, true)

        try do
          fun.()
        after
          restore_lock_marker(lock_marker, previous)
        end
      end)
    end
  end

  defp begin_public_comment_lock(ticket, command, operation_id, path) do
    lock_marker = {__MODULE__, path}
    pending_key = pending_public_comment_key(operation_id)

    if Process.get(pending_key) do
      {:error, :public_comment_operation_already_pending}
    else
      case :global.set_lock({lock_marker, self()}, [node()]) do
        true ->
          pending = %{
            path: path,
            ticket: ticket,
            command: command,
            operation_id: operation_id,
            lock_marker: lock_marker
          }

          Process.put(lock_marker, true)
          persist_public_comment_lock(pending, pending_key)

        false ->
          {:error, :public_comment_origin_lock_unavailable}
      end
    end
  end

  defp pop_pending_public_comment(operation_id, command) when is_binary(operation_id) do
    pending_key = pending_public_comment_key(operation_id)

    case Process.get(pending_key) do
      %{} = pending ->
        Process.delete(pending_key)
        pending

      nil ->
        pop_pending_public_comment_by_command(command)
    end
  end

  defp pop_pending_public_comment(_operation_id, _command), do: nil

  defp persist_public_comment_lock(pending, pending_key) do
    case persist_pending_public_comment(pending) do
      :ok ->
        Process.put(pending_key, pending)
        :ok

      {:error, _reason} = error ->
        release_public_comment_lock(pending)
        error
    end
  end

  defp pop_pending_public_comment_by_command(command) when is_binary(command) do
    pending =
      Process.get()
      |> Enum.find_value(fn
        {{__MODULE__, :pending_public_comment, _operation_id} = pending_key, %{} = pending}
        when pending.command == command ->
          {pending_key, pending}

        _entry ->
          nil
      end)

    case pending do
      {pending_key, pending} ->
        Process.delete(pending_key)
        pending

      nil ->
        nil
    end
  end

  defp pop_pending_public_comment_by_command(_command), do: nil

  defp put_pending_public_comment(%{operation_id: operation_id} = pending) do
    Process.put(pending_public_comment_key(operation_id), pending)
    :ok
  end

  defp pending_public_comment_key(operation_id), do: {__MODULE__, :pending_public_comment, operation_id}

  defp release_public_comment_lock(%{lock_marker: lock_marker}) do
    Process.delete(lock_marker)
    :global.del_lock({lock_marker, self()}, [node()])
    :ok
  end

  defp finalize_pending_public_comment(pending, result) when result in [:ok, :ignored] do
    case clear_pending_public_comment(pending) do
      :ok ->
        release_public_comment_lock(pending)
        :ok

      {:error, _reason} = error ->
        put_pending_public_comment(pending)
        error
    end
  end

  defp finalize_pending_public_comment(pending, {:error, _reason} = error) do
    put_pending_public_comment(pending)
    error
  end

  defp finalize_pending_public_comment(pending, other) do
    put_pending_public_comment(pending)
    {:error, {:invalid_origin_recorder_result, other}}
  end

  @spec record(String.t() | integer(), map()) :: :ok | {:error, term()}
  def record(ticket, verified_comment), do: record(ticket, verified_comment, [])

  @doc false
  @spec record(String.t() | integer(), map(), keyword()) :: :ok | {:error, term()}
  def record(ticket, verified_comment, opts) when is_map(verified_comment) and is_list(opts) do
    with {:ok, path} <- path_for(),
         {:ok, ticket} <- normalize_ticket(ticket),
         {:ok, comment_id} <- comment_id(verified_comment) do
      persist(path, ticket, comment_id, opts)
    end
  end

  def record(_ticket, _verified_comment, _opts), do: {:error, :invalid_verified_comment}

  @spec origin(String.t() | integer(), map()) :: :agent | :external
  def origin(ticket, comment) when is_map(comment) do
    with {:ok, path} <- path_for(),
         {:ok, ticket} <- normalize_ticket(ticket),
         {:ok, comment_id} <- comment_id(comment),
         {:ok, state} <- with_lock(path, fn -> load_state(path) end) do
      cond do
        comment_id in Map.get(state.origins, ticket, []) ->
          :agent

        Map.has_key?(state.pending, ticket) ->
          Logger.warning(
            "Agent comment origin quarantined pending durable recovery: " <>
              "ticket=#{ticket} comment_id=#{comment_id} pending_operations=#{inspect(Map.get(state.pending, ticket))}"
          )

          :agent

        true ->
          :external
      end
    else
      {:error, reason} ->
        Logger.warning("Agent comment origin lookup failed: ticket=#{inspect(ticket)} reason=#{inspect(reason)}")
        :external

      other ->
        Logger.warning("Agent comment origin lookup failed: ticket=#{inspect(ticket)} reason=#{inspect(other)}")
        :external
    end
  end

  def origin(_ticket, _comment), do: :external

  defp persist(path, ticket, comment_id, opts) do
    with_lock(path, fn ->
      with {:ok, state} <- load_state(path) do
        origins = state.origins
        run_after_load_hook(Keyword.get(opts, :after_load), ticket, origins)
        ids = [comment_id | Map.get(origins, ticket, [])] |> Enum.uniq() |> Enum.take(@max_origins_per_ticket)
        write_state(path, %{state | origins: Map.put(origins, ticket, ids)})
        :ok
      end
    end)
  rescue
    error -> {:error, {:persistence_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:persistence_failed, {kind, reason}}}
  end

  defp run_after_load_hook(hook, ticket, origins) when is_function(hook, 2), do: hook.(ticket, origins)
  defp run_after_load_hook(_hook, _ticket, _origins), do: :ok

  defp restore_lock_marker(lock_marker, :unset), do: Process.delete(lock_marker)
  defp restore_lock_marker(lock_marker, previous), do: Process.put(lock_marker, previous)

  defp stable_path_for do
    with {:ok, state_dir} <- Paths.decision_state_dir() do
      {:ok, Path.join(state_dir, "agent-comment-origins.json")}
    end
  end

  defp persist_pending_public_comment(pending) do
    with_lock(pending.path, fn ->
      with {:ok, state} <- load_state(pending.path) do
        pending_operations = Map.get(state.pending, pending.ticket, [])

        updated_pending =
          pending_operations
          |> Enum.reject(&(&1 == pending.operation_id))
          |> then(&[pending.operation_id | &1])

        write_state(pending.path, %{state | pending: Map.put(state.pending, pending.ticket, updated_pending)})
        :ok
      end
    end)
  rescue
    error -> {:error, {:persistence_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:persistence_failed, {kind, reason}}}
  end

  defp clear_pending_public_comment(pending) do
    with_lock(pending.path, fn ->
      with {:ok, state} <- load_state(pending.path) do
        updated_pending = drop_pending_operation(state.pending, pending.ticket, pending.operation_id)

        write_state(pending.path, %{state | pending: updated_pending})
        :ok
      end
    end)
  rescue
    error -> {:error, {:persistence_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:persistence_failed, {kind, reason}}}
  end

  defp drop_pending_operation(pending, ticket, operation_id) do
    case pending |> Map.get(ticket, []) |> Enum.reject(&(&1 == operation_id)) do
      [] -> Map.delete(pending, ticket)
      pending_operations -> Map.put(pending, ticket, pending_operations)
    end
  end

  defp load_state(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{} = persisted} ->
        {:ok,
         %{
           origins: normalize_origins(Map.get(persisted, "origins", %{})),
           pending: normalize_pending(Map.get(persisted, "pending", %{}))
         }}

      {:ok, _other} ->
        {:error, :invalid_store_shape}

      {:error, reason} ->
        {:error, {:store_read_failed, reason}}
    end
  end

  defp write_state(path, %{origins: origins, pending: pending}) do
    JsonStore.write!(path, %{"origins" => origins, "pending" => pending})
  end

  defp normalize_origins(origins) when is_map(origins) do
    Enum.reduce(origins, %{}, fn
      {ticket, ids}, acc when is_binary(ticket) and is_list(ids) ->
        normalized_ids =
          ids
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.uniq()
          |> Enum.take(@max_origins_per_ticket)

        if normalized_ids == [], do: acc, else: Map.put(acc, ticket, normalized_ids)

      _entry, acc ->
        acc
    end)
  end

  defp normalize_origins(_origins), do: %{}

  defp normalize_pending(pending) when is_map(pending) do
    Enum.reduce(pending, %{}, fn
      {ticket, operations}, acc when is_binary(ticket) and is_list(operations) ->
        operations = operations |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()
        if operations == [], do: acc, else: Map.put(acc, ticket, operations)

      _entry, acc ->
        acc
    end)
  end

  defp normalize_pending(_pending), do: %{}

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

  defp agent_comment_command?(command) do
    gh_pr_comment?(command) or gh_api_comment_post?(command)
  end

  defp gh_pr_comment?(command) do
    Regex.match?(~r/(?:\A|[^[:alnum:]_])gh\s+pr\s+comment(?:\s|\z)/, command)
  end

  defp gh_api_comment_post?(command) do
    Regex.match?(~r/(?:\A|[^[:alnum:]_])gh\s+api(?:\s|\z)/, command) and
      Regex.match?(~r{/issues/\d+/comments(?=\s|\z|["'])}, command) and
      Regex.match?(~r/(?:--method|-X)\s*=?\s*POST\b/i, command)
  end

  defp gh_comment_id_from_output(output) do
    case Regex.run(~r/#issuecomment-(\d+)\b/, output) ||
           Regex.run(~r/"id"\s*:\s*(\d+)\b/, output) do
      [_, comment_id] -> {:ok, comment_id}
      _ -> {:error, :gh_pr_comment_id_missing}
    end
  end
end
