defmodule Aiur.OpenTicketSource.Snapshot do
  @moduledoc """
  Compact snapshot of every open tracker ticket on the configured repository.

  `status` mirrors the named states the rest of the dashboard uses, so a failed
  listing presents a stale or unavailable region rather than an empty healthy
  table. `:unsupported` is distinct from a fault: a non-GitHub tracker has no
  such listing at all, which is a configuration fact, not an outage.
  `truncated?` marks a listing cut short by the page budget, so a bounded prefix
  is never presented as an exact count. `tickets` are open issues only — pull
  requests share GitHub's issue endpoint and are excluded at the source.
  """

  alias Aiur.TrackerIdentity

  @type status :: :available | :stale | :unavailable | :unsupported

  @type ticket :: %{
          identity: TrackerIdentity.t() | nil,
          identifier: String.t(),
          title: String.t() | nil,
          url: String.t() | nil,
          state: String.t() | nil,
          labels: [String.t()],
          assignee: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type t :: %__MODULE__{
          status: status(),
          generation: pos_integer() | nil,
          observed_at: DateTime.t() | nil,
          truncated?: boolean(),
          tickets: [ticket()]
        }

  defstruct status: :unavailable, generation: nil, observed_at: nil, truncated?: false, tickets: []
end
