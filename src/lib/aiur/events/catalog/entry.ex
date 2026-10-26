defmodule Aiur.Events.Catalog.Entry do
  @moduledoc "A topic's durability, ownership and identifier-only export contract."

  # aiur:event-bus-boundary-member

  @type class :: :ephemeral | :live | :ledgered | :logged | :journaled
  @type attr_type :: {:enum, [String.t()]} | :integer | :boolean | :id | :sha
  @type t :: %__MODULE__{
          pattern: String.t(),
          class: class(),
          export?: boolean(),
          refs: [atom()],
          attrs: [{atom(), attr_type()}],
          payload_version: pos_integer(),
          owner: String.t()
        }

  @enforce_keys [:pattern, :class, :owner]
  defstruct pattern: nil, class: :live, export?: false, refs: [], attrs: [], payload_version: 1, owner: nil

  @doc false
  @spec alert(String.t(), String.t(), keyword()) :: t()
  def alert(pattern, owner, opts \\ []) do
    %__MODULE__{
      pattern: pattern,
      class: :ledgered,
      export?: Keyword.get(opts, :export?, false),
      refs: [:ticket],
      attrs: [severity: {:enum, ~w(info warning error)}, needs_attention: :boolean],
      owner: owner
    }
  end
end
