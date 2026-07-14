defmodule Aiur.GitHub.AgentCommentOrigins.Store do
  @moduledoc false

  alias Aiur.JsonStore

  @spec with_ticket_lock(Path.t(), String.t(), (-> term())) :: term()
  def with_ticket_lock(path, ticket, fun) when is_binary(path) and is_binary(ticket) and is_function(fun, 0) do
    marker = {__MODULE__, path, ticket}

    if Process.get(marker) do
      fun.()
    else
      :global.trans({marker, self()}, fn ->
        previous = Process.get(marker, :unset)
        Process.put(marker, true)

        try do
          fun.()
        after
          restore_marker(marker, previous)
        end
      end)
    end
  end

  @spec read(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(path, ticket) when is_binary(path) and is_binary(ticket) do
    case JsonStore.read(ticket_path(path, ticket), :missing) do
      {:ok, :missing} -> read_legacy(path, ticket)
      {:ok, %{} = state} -> {:ok, state}
      {:ok, _other} -> {:error, :invalid_store_shape}
      {:error, reason} -> {:error, {:store_read_failed, reason}}
    end
  end

  @spec write(Path.t(), String.t(), map()) :: :ok
  def write(path, ticket, state) when is_binary(path) and is_binary(ticket) and is_map(state) do
    JsonStore.write!(ticket_path(path, ticket), state)
  end

  @spec ticket_path(Path.t(), String.t()) :: Path.t()
  def ticket_path(path, ticket) do
    encoded_ticket = Base.url_encode64(ticket, padding: false)
    Path.join([Path.dirname(path), Path.basename(path) <> ".tickets", encoded_ticket <> ".json"])
  end

  defp read_legacy(path, ticket) do
    case JsonStore.read(path, %{}) do
      {:ok, %{} = legacy} ->
        {:ok,
         %{
           "origins" => get_in(legacy, ["origins", ticket]) || [],
           "pending" => get_in(legacy, ["pending", ticket]) || []
         }}

      {:ok, _other} ->
        {:error, :invalid_store_shape}

      {:error, reason} ->
        {:error, {:store_read_failed, reason}}
    end
  end

  defp restore_marker(marker, :unset), do: Process.delete(marker)
  defp restore_marker(marker, previous), do: Process.put(marker, previous)
end
