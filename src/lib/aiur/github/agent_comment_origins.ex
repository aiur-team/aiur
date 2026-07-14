defmodule Aiur.GitHub.AgentCommentOrigins do
  @moduledoc false

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @max_origins_per_ticket 100

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
         {:ok, origins} <- with_lock(path, fn -> load_origins(path) end) do
      if comment_id in Map.get(origins, ticket, []), do: :agent, else: :external
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
      with {:ok, origins} <- load_origins(path) do
        run_after_load_hook(Keyword.get(opts, :after_load), ticket, origins)
        ids = [comment_id | Map.get(origins, ticket, [])] |> Enum.uniq() |> Enum.take(@max_origins_per_ticket)
        JsonStore.write!(path, %{"origins" => Map.put(origins, ticket, ids)})
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

  defp load_origins(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{} = persisted} -> {:ok, normalize_origins(Map.get(persisted, "origins", %{}))}
      {:ok, _other} -> {:error, :invalid_store_shape}
      {:error, reason} -> {:error, {:store_read_failed, reason}}
    end
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
      Regex.match?(~r{/issues/\d+/comments(?:\s|\z)}, command) and
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
