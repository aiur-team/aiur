defmodule Aiur.Events.Export do
  @moduledoc "Read-only external event feed. Reads never call the exporter process."
  # aiur:event-bus-boundary-member
  alias Aiur.Events.Export.{Layout, Reader}

  @doc false
  @spec floor_files() :: [Path.t()]
  def floor_files do
    with {:ok, dir} <- Layout.directory(),
         {_, path} <- List.last(Layout.segments(dir)) do
      [path]
    else
      _ -> []
    end
  end

  @spec enabled?() :: boolean()
  def enabled?, do: status().state != :disabled

  @spec status() :: map()
  def status do
    :persistent_term.get({__MODULE__, :status}, %{state: :disabled, reason: nil, instance: nil, epoch: nil, oldest_seq: nil, head_seq: nil})
  end

  @spec read(non_neg_integer(), 1..500, [String.t()], keyword()) :: {:ok, map()} | {:reset, map()} | {:error, :events_unavailable}
  def read(after_seq, limit, patterns, opts \\ []) do
    Reader.read(status(), after_seq, limit, patterns, opts)
  end
end
