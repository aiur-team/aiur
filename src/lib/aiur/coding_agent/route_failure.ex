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
  | Auth rejected (401) | `:auth_rejected` | skip backend | persistent backend hold | once per backend |
  | Anything else | `:fatal` | no | never | no (surfaced by the caller) |

  The two load-bearing distinctions:

  **A transient error must never reach the limit ledger.** `model-usage.json`
  means exactly one thing — "this account is rate-limited until `reset_at`".
  Writing a provider outage into it would make the outage indistinguishable
  from a quota event: it would suppress the alert, and the route would then sit
  out until a `reset_at` that was never real. So a transient failure moves the
  claim along and raises an attention, and leaves the ledger untouched. This is
  the conflation that hides an outage.

  **A 401 pauses its backend.** The credential is persisted as rejected, one
  dashboard attention is raised, and later claims skip that backend until its
  credential changes. Other configured backends remain available.
  """

  require Logger

  alias Aiur.CodingAgent.ProviderCredential
  alias Aiur.Issue
  alias Aiur.ModelAvailability
  alias Aiur.Signal

  @type class :: :usage_limit | :transient | :auth_rejected | :fatal

  @doc "The failure class of a transport error, as returned by `Aiur.OpenAICompat.Transport.complete/3`."
  @spec classify(term()) :: class()
  def classify(:rate_limited), do: :usage_limit
  def classify({:http_error, 429, _detail}), do: :usage_limit
  def classify(:unauthorized), do: :auth_rejected

  def classify({:turn_failed, details}) when is_map(details),
    do: if(unauthorized_status?(details), do: :auth_rejected, else: :fatal)

  def classify({:http_error, status, _detail}) when status == 401, do: :auth_rejected
  def classify({:http_error, status, _detail}) when status >= 500, do: :transient
  def classify(:invalid_response), do: :transient
  def classify(:invalid_response_body), do: :transient
  def classify(:invalid_chat_completion), do: :transient
  def classify({:incomplete_provider_response, _status}), do: :transient
  def classify(:timeout), do: :transient
  def classify(%{reason: :timeout}), do: :transient
  def classify(%Req.TransportError{}), do: :transient
  def classify(_reason), do: :fatal

  defp unauthorized_status?(details) when is_map(details) do
    Enum.any?(details, fn
      {key, value}
      when key in [
             "status",
             :status,
             "status_code",
             :status_code,
             "statusCode",
             :statusCode,
             "api_error_status",
             :api_error_status,
             "apiErrorStatus",
             :apiErrorStatus,
             "http_status",
             :http_status,
             "httpStatus",
             :httpStatus
           ] ->
        value in [401, "401"]

      {_key, value} when is_map(value) ->
        unauthorized_status?(value)

      {_key, value} when is_list(value) ->
        Enum.any?(value, &unauthorized_status?(&1))

      _ ->
        false
    end)
  end

  defp unauthorized_status?(_details), do: false

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
    backend = ModelAvailability.backend_key(route)
    availability_opts = Keyword.get(opts, :availability_opts, [])
    fingerprint = ProviderCredential.fingerprint(backend, Aiur.Config.settings!(), System.get_env()) || "unavailable"

    settings = Aiur.Config.settings!()
    path = if settings.instance.mode == "hosted", do: Path.join(System.get_env("AIUR_BG_STATE_DIR") || Path.expand("~/.config/aiur"), "model-usage.json"), else: ModelAvailability.path()
    availability_opts = Keyword.put_new(availability_opts, :path, path)

    case ModelAvailability.auth_rejected_alert_once(backend, fingerprint, availability_opts) do
      {:ok, :first} ->
        Signal.alert("system.provider.auth_rejected.#{backend}",
          reason:
            "The #{backend} provider rejected its credential (HTTP 401). Dispatch is paused for this backend until its credential is changed. Update the key or login, then restart Aiur. Other configured backends remain available.",
          needs_attention: true,
          severity: "critical"
        )

      {:ok, :already_held} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not persist provider auth hold backend=#{backend} reason=#{inspect(reason)}")
        emit_system(issue, "auth_rejected", opts, "The #{backend} provider rejected its credential (HTTP 401), but the dispatch hold could not be persisted.")
    end
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
    Signal.alert(
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
