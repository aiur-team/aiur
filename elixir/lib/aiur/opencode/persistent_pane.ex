defmodule Aiur.Opencode.PersistentPane do
  @moduledoc """
  Per-identifier pane state: which opencode session the agent owns, the
  tmux pane id of its `opencode attach` process, and its current
  visibility status.

  Stored as the registered value in `Aiur.Opencode.SessionWriterRegistry`
  (one entry per identifier), so SessionWriter pid, session id, pane
  id, and status all live in one source of truth. PaneManager and
  AttachQueue mutate status via the registry helpers; readers should
  prefer `SessionWriterRegistry.get_pane/1` over inspecting the raw
  registry value.

  Status transitions:
      :pending     -- enqueued, no attach work has begun
      :attaching   -- AttachQueue is currently spawning + replaying
      :hidden      -- pane lives in the hidden warm window, ready to swap
      :visible     -- pane lives in the visible agents window
  """

  @type status :: :pending | :attaching | :hidden | :visible

  @type t :: %__MODULE__{
          identifier: String.t(),
          session_id: String.t(),
          pane_id: String.t() | nil,
          status: status(),
          attached_at: integer() | nil
        }

  @enforce_keys [:identifier, :session_id]
  defstruct identifier: nil,
            session_id: nil,
            pane_id: nil,
            status: :pending,
            attached_at: nil

  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(identifier, session_id, opts \\ [])
      when is_binary(identifier) and is_binary(session_id) do
    %__MODULE__{
      identifier: identifier,
      session_id: session_id,
      pane_id: Keyword.get(opts, :pane_id),
      status: Keyword.get(opts, :status, :pending),
      attached_at: Keyword.get(opts, :attached_at)
    }
  end

  @spec with_pane_id(t(), String.t()) :: t()
  def with_pane_id(%__MODULE__{} = pane, pane_id) when is_binary(pane_id) do
    %{pane | pane_id: pane_id, attached_at: pane.attached_at || System.monotonic_time(:millisecond)}
  end

  @spec with_status(t(), status()) :: t()
  def with_status(%__MODULE__{} = pane, status)
      when status in [:pending, :attaching, :hidden, :visible] do
    %{pane | status: status}
  end
end
