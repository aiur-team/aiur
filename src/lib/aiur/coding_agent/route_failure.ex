defmodule Aiur.CodingAgent.RouteFailure do
  @moduledoc """
  Classification of a *request-time* route failure into the four causes #1923
  insists must never be conflated, and the disposition each one gets.

  `Aiur.CodingAgent.RouteCredentials` covers the fifth cause (no key at all),
  which is decided before a request exists.

  | Cause | `class` | Advances to the next route? | Written to `model-usage.json`? | Alert |
  |---|---|---|---|---|
  | Usage / rate limit (429) | `:usage_limit` | yes | **yes**, with `reset_at` | the existing quota alert |
  | Transient (5xx, timeout, malformed body) | `:transient` | for **this claim only** | **never** | yes |
  | Auth rejected (401) | `:auth_rejected` | **no** | never | yes |
  | Anything else | `:fatal` | no | never | no (surfaced by the caller) |

  The two load-bearing distinctions:

  **A transient error must never reach the limit ledger.** `model-usage.json`
  means exactly one thing — "this account is rate-limited until `reset_at`".
  Writing a provider outage into it would make the outage indistinguishable
  from a quota event: it would suppress the alert, and the route would then sit
  out until a `reset_at` that was never real. So a transient failure moves the
  claim along and raises an attention, and leaves the ledger untouched. This is
  the conflation that hides an outage.

  **A 401 must not fall through.** It is the one failure that looks like an
  outage but is a config error: a key that is present and wrong. Advancing
  would silently move the fleet's spend onto the next route — very plausibly a
  paid OpenRouter path — and leave a broken credential undetected for as long
  as the fallback holds. A typo'd key stopping the fleet is loud, and loud is
  the point.
  """

  alias Aiur.Alerts
  alias Aiur.Config.RoutingValue
  alias Aiur.Issue

  @type class :: :usage_limit | :transient | :auth_rejected | :fatal

  @doc "The failure class of a transport error, as returned by `Aiur.OpenAICompat.Transport.complete/3`."
  @spec classify(term()) :: class()
  def classify(:rate_limited), do: :usage_limit
  def classify({:http_error, 429, _detail}), do: :usage_limit
  def classify(:unauthorized), do: :auth_rejected
  def classify({:http_error, status, _detail}) when status in [401, 403], do: :auth_rejected
  def classify({:http_error, status, _detail}) when status >= 500, do: :transient
  def classify(:invalid_response), do: :transient
  def classify(:invalid_response_body), do: :transient
  def classify(:invalid_chat_completion), do: :transient
  def classify({:incomplete_provider_response, _status}), do: :transient
  def classify(:timeout), do: :transient
  def classify(%{reason: :timeout}), do: :transient
  def classify(%Req.TransportError{}), do: :transient
  def classify(_reason), do: :fatal

  @doc """
  Whether the claim may advance to the next `agent.priority` route.

  True for a usage limit (the ledger remembers, so this is self-healing) and
  for a transient error (this claim only — nothing is remembered, so the next
  claim retries the same route and an ongoing outage keeps alerting rather than
  silently disappearing). False for a rejected credential, deliberately.
  """
  @spec advance?(class()) :: boolean()
  def advance?(class), do: class in [:usage_limit, :transient]

  @doc """
  Whether the failure belongs in `model-usage.json`. Only a real usage limit
  does; see the moduledoc for why a transient error must not.
  """
  @spec record_limit?(class()) :: boolean()
  def record_limit?(class), do: class == :usage_limit

  @doc """
  Raises the operator attention a route failure warrants, and returns the
  class. A usage limit is intentionally silent here — it already has its own
  alert on the pause path (`Aiur.AgentRunner.TurnAlerts`), and duplicating it
  would make the quota case noisier than the outage case.
  """
  @spec alert(Issue.t(), String.t(), term(), keyword()) :: class()
  def alert(%Issue{} = issue, route, reason, opts \\ []) when is_binary(route) do
    class = classify(reason)
    emit(class, issue, route, reason, opts)
    class
  end

  defp emit(:auth_rejected, issue, route, _reason, opts) do
    emit_system(
      issue,
      "auth_rejected",
      opts,
      "Route #{route} rejected aiur's credential (401). Dispatch has NOT fallen through to the next " <>
        "agent.priority entry: a bad key would otherwise move spend silently onto another route and " <>
        "stay hidden. Fix or remove the credential for #{RoutingValue.routing_backend(route)}."
    )
  end

  defp emit(:transient, issue, route, reason, opts) do
    emit_system(
      issue,
      "transient",
      opts,
      "Route #{route} failed transiently (#{inspect(reason)}) after its retries. This claim advances to " <>
        "the next agent.priority entry; the route is NOT marked rate-limited, so the next claim tries it " <>
        "again and this alert repeats while the outage lasts."
    )
  end

  defp emit(_class, _issue, _route, _reason, _opts), do: :ok

  defp emit_system(issue, suffix, opts, reason) do
    Alerts.emit_system(
      "ticket.#{issue.identifier}.agent.route.#{suffix}",
      issue: issue,
      workspace: Keyword.get(opts, :workspace),
      worker_host: Keyword.get(opts, :worker_host),
      reason: reason,
      needs_attention: true,
      severity: "warning"
    )

    :ok
  end
end
