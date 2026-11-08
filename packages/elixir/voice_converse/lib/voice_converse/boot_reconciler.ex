defmodule VoiceConverse.BootReconciler do
  @moduledoc false

  use GenServer

  alias VoiceConverse.{ProviderCleanup, TranscriptIndex}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :transcript_root)
    cleanup = Keyword.fetch!(opts, :cleanup)

    case TranscriptIndex.reconcile(root, enqueue: &ProviderCleanup.enqueue(cleanup, &1, &2)) do
      {:ok, _result} -> {:ok, %{root: root}}
      {:error, reason} -> {:stop, reason}
    end
  end
end
