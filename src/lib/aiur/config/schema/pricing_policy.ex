defmodule Aiur.Config.Schema.PricingPolicy do
  @moduledoc """
  Cost-aware dispatch policy — the knobs that decide whether spend influences
  which `agent.priority` route is chosen.

  Landed here as **shape first**, then wired: the fields are validated,
  defaulted and documented, and `Aiur.CodingAgent`'s peak-pricing route policy
  now reads `avoid_peak_pricing` at dispatch time (see the policy's failure
  direction below).

  ## `avoid_peak_pricing`

  Some providers charge a deliberately different rate inside a window of the
  day (DeepSeek's peak/off-peak schedule is the live case). The price table
  prices a call at the rate actually in force — revisions are effective-dated
  and self-describing via their `window` tag (peak/off-peak), resolved from the
  occurrence time against a hand-maintained schedule. `avoid_peak_pricing`
  *acts* on the same window at selection time: a route whose billing provider
  is currently peak-priced is skipped and the next `agent.priority` entry is
  used.

  Default `true`: routing away from a peak window is the product default,
  because the operator writing an ordered fallback list has already said what
  to use instead.

  **`false` means: ignore pricing windows entirely and use `agent.priority`
  exactly as written.** It does *not* mean "still reroute but stay quiet", and
  it does not change cost *reporting* — a call that lands in a peak window is
  still priced and displayed at the peak rate either way. Reporting and routing
  are deliberately separate: turning routing off must never make spend look
  cheaper than it was.

  ## Why the failure direction is "do not reroute"

  Peak windows are **not API-discoverable** — no provider exposes a tier
  indicator, so the window boundaries can only be a hand-maintained table
  compared against the clock. DeepSeek has changed regime three times in
  eighteen months, once inverting which half of the day was expensive. The
  table will therefore be stale at some point, and the question is which way it
  should be wrong.

  When the window data is missing, stale, or unparseable, this policy must
  **fail toward not rerouting** and use `agent.priority` as written. A stale
  window that wrongly believes it is peak would quietly move the operator's
  work to a different provider for a reason that is no longer true, and the
  symptom — work running somewhere unexpected — is far harder to notice than
  paying a peak rate that is visible on a meter. Correct-but-costlier beats
  silently-wrong-routing.

  ## Granularity

  Deliberately **global**. Per-backend or per-route granularity is a plausible
  want ("avoid peak for DeepSeek but not for X"), but nobody has asked for it,
  and the narrower key can be added later without breaking this one; a global
  key cannot be extracted back out of a per-route one. Per-route avoidance is
  in any case already expressible by simply not listing the route.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:avoid_peak_pricing, :boolean, default: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:avoid_peak_pricing], empty_values: [])
  end
end
