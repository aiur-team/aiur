defmodule Aiur.Events.Journal do
  @moduledoc "Append/replay for bus-owned journals, backed by the kernel journal."

  # aiur:event-bus-boundary-member

  alias Aiur.Journal, as: KernelJournal

  @type replay_error :: {:corrupt, pos_integer(), term()} | {:journal_unavailable, term()}

  @spec prepare(Path.t(), Path.t()) :: :ok | {:error, term()}
  def prepare(dir, path), do: KernelJournal.prepare(dir, path)

  @spec append(Path.t(), map()) :: :ok | {:error, term()}
  def append(path, record), do: KernelJournal.append(path, record)

  @spec replay(Path.t(), (map() -> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, [term()]} | {:error, replay_error()}
  def replay(path, validator, opts \\ []) do
    {on_corrupt, opts} = Keyword.pop(opts, :on_corrupt, fn _line, _reason -> :ok end)

    case KernelJournal.replay(path, validator, opts) do
      {:ok, records, nil} ->
        {:ok, records}

      {:ok, _prefix, {:corrupt, line, reason}} ->
        _ = on_corrupt.(line, reason)
        {:error, {:corrupt, line, reason}}

      {:error, reason} ->
        {:error, {:journal_unavailable, reason}}
    end
  end
end
