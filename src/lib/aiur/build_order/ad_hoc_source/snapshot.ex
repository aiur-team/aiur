defmodule Aiur.BuildOrder.AdHocSource.Snapshot do
  @moduledoc """
  Compact snapshot of the derived Ad Hoc Build Order overlay.

  `status` mirrors the named states the graph uses so the overlay can present a
  stale/unavailable region instead of an empty healthy table. `members` are the
  normalized `build-lane:adhoc` issues; downstream projection derives pickup
  phase, complexity, and live progress. Point/critical-path totals never fold
  these members.
  """

  alias Aiur.TrackerIdentity

  @type status :: :available | :stale | :unavailable

  @type member :: %{
          identity: TrackerIdentity.t(),
          identifier: String.t(),
          title: String.t() | nil,
          url: String.t() | nil,
          lifecycle: :open | :closed,
          labels: [String.t()]
        }

  @type t :: %__MODULE__{
          status: status(),
          generation: pos_integer() | nil,
          observed_at: DateTime.t() | nil,
          members: [member()]
        }

  defstruct status: :unavailable, generation: nil, observed_at: nil, members: []
end
