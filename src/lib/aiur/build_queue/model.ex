defmodule Aiur.BuildQueue.Model do
  @moduledoc """
  Pure queue domain records and the version 1 store document.

  `encode/1` returns a JSON-ready map for JsonStore; `decode/1` consumes that
  map after JSON parsing. The domain document has atom keys and lists of
  records. Observations, titles, bodies, and extra keys are never persisted.
  Wall-clock timestamps are UTC DateTimes; `_ms` fields are Unix milliseconds.
  Build-order items use a nil position. Nullable fields must still be present.
  Error reasons and latch keys use Base64 Erlang terms; safe decoding rejects
  atoms not already loaded in the VM. Load producer modules before store recovery.
  """

  alias Aiur.BuildQueue.Codec

  defmodule Queue do
    @moduledoc "A named list or imported build order."
    @enforce_keys [:id, :name, :kind, :root, :held, :generation, :created_at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            kind: :list | :build_order,
            root: pos_integer() | nil,
            held: boolean(),
            generation: non_neg_integer(),
            created_at: DateTime.t()
          }
  end

  defmodule Item do
    @moduledoc "Queue membership and operator provenance."
    @enforce_keys [:issue_id, :queue_id, :position, :hold, :override, :promoted_at, :added_at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            issue_id: String.t(),
            queue_id: String.t(),
            position: non_neg_integer() | nil,
            hold: nil | :operator | :external,
            override: nil | :manual_promotion,
            promoted_at: DateTime.t() | nil,
            added_at: DateTime.t()
          }
  end

  defmodule Edge do
    @moduledoc "A prerequisite-to-dependent edge and its provenance."
    @enforce_keys [:prerequisite, :dependent, :source]
    defstruct @enforce_keys
    @type t :: %__MODULE__{prerequisite: String.t(), dependent: String.t(), source: :list | :build_order | :native}
  end

  defmodule Observation do
    @moduledoc "Transient tracker evidence, never stored in a queue document."
    @enforce_keys [:issue_id, :open?, :labels, :state_reason, :pr, :observed_at_ms]
    defstruct @enforce_keys ++ [unavailable_reason: nil]

    @type t :: %__MODULE__{
            unavailable_reason: nil | :closed_reason,
            issue_id: String.t(),
            open?: boolean() | :unknown,
            labels: [String.t()],
            state_reason: String.t() | nil,
            pr: nil | :closed_unmerged | :merged | :open,
            observed_at_ms: non_neg_integer()
          }
  end

  defmodule Intent do
    @moduledoc "A durable label write intent and its outcome."
    @enforce_keys [:id, :issue_id, :action, :target_labels, :recorded_at_ms, :outcome]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            issue_id: String.t(),
            action: :promote | :withdraw | :mark | :unmark,
            target_labels: [String.t()],
            recorded_at_ms: non_neg_integer(),
            outcome: nil | :ok | {:error, term()}
          }
  end

  defmodule Latch do
    @moduledoc "A durable attention keyed by cause and subject."
    @enforce_keys [:key, :opened_at_ms]
    defstruct @enforce_keys ++ [emitted?: false]
    @type t :: %__MODULE__{key: {term(), term()}, opened_at_ms: non_neg_integer(), emitted?: boolean()}
  end

  @type t :: %{queues: [Queue.t()], items: [Item.t()], edges: [Edge.t()], intents: [Intent.t()], latches: [Latch.t()]}

  @spec encode(t()) :: map()
  def encode(document), do: Codec.encode(document)

  @spec decode(term()) :: {:ok, t()} | {:error, {:unsupported_version, term()} | {:invalid, list()}}
  def decode(document), do: Codec.decode(document)
end
