defmodule Aiur.Events.GithubWebhook do
  @moduledoc """
  Publish tail for verified GitHub webhook deliveries.

  `Aiur.Events.GithubWebhook.Normalizer` decides *what* a delivery means;
  this module performs the same publish the pollers perform —
  `Aiur.Events.Sanitizer.github_payload/2` followed by
  `Aiur.Events.Publisher.publish/3` — so push and poll are indistinguishable
  to every consumer, and `Publisher`'s replay dedup collapses the pair when
  both observe the same GitHub event.

  Deliveries whose event is owned by a stateful reconciler (label transitions,
  CI outcomes, `synchronize`) do not publish here. They nudge the orchestrator
  to run its poll cycle now, so the *existing* producer emits the *existing*
  event without a poll-interval wait. Consecutive nudges are coalesced.

  Nothing in this module is allowed to take down the caller. The receiver is an
  HTTP endpoint holding an unvalidated payload from the public internet: an
  unrecognized event type is logged and ignored, a malformed payload is
  rejected, and an unexpected exception is caught and reported as an error
  rather than raised.
  """

  require Logger

  alias Aiur.Events.GithubWebhook.Normalizer
  alias Aiur.Events.{Publisher, Sanitizer}

  @reconcile_debounce_ms 2_000

  @type outcome :: %{
          required(:status) => :published | :reconciled | :dropped | :error,
          optional(:published) => [String.t()],
          optional(:results) => [term()],
          optional(:reason) => term(),
          optional(:hint) => map()
        }

  @doc """
  Handles one verified delivery.

  `event_type` is the `X-GitHub-Event` header value; `payload` is the decoded
  JSON body. Always returns an outcome map; never raises.

  Options are passed through to `Normalizer.normalize/3` (notably `:repo`),
  plus:

    * `:publish_fun` — 3-arity override for `Publisher.publish/3` (test seam)
    * `:reconcile_fun` — 1-arity override for the orchestrator nudge
    * `:orchestrator` — process name or pid to nudge; defaults to
      `Aiur.Orchestrator`
  """
  @spec handle_delivery(term(), term(), keyword()) :: outcome()
  def handle_delivery(event_type, payload, opts \\ []) do
    case Normalizer.normalize(event_type, payload, opts) do
      {:publish, triples} ->
        publish_all(triples, opts)

      {:reconcile, hint} ->
        request_reconcile(hint, opts)
        %{status: :reconciled, hint: hint}

      {:drop, {:unsupported_event, type} = reason} ->
        Logger.debug("GithubWebhook ignoring unsupported delivery type=#{inspect(type)}")
        %{status: :dropped, reason: reason}

      {:drop, reason} ->
        Logger.debug("GithubWebhook dropped delivery type=#{inspect(event_type)} reason=#{inspect(reason)}")
        %{status: :dropped, reason: reason}

      {:error, reason} ->
        Logger.warning("GithubWebhook rejected delivery type=#{inspect(event_type)} reason=#{inspect(reason)}")
        %{status: :error, reason: reason}
    end
  rescue
    error ->
      Logger.error("GithubWebhook delivery raised type=#{inspect(event_type)} error=#{Exception.message(error)}")
      %{status: :error, reason: {:exception, Exception.message(error)}}
  catch
    kind, reason ->
      Logger.error("GithubWebhook delivery exited type=#{inspect(event_type)} reason=#{inspect({kind, reason})}")
      %{status: :error, reason: {kind, reason}}
  end

  defp publish_all(triples, opts) do
    publish_fun = Keyword.get(opts, :publish_fun, &Publisher.publish/3)

    results =
      Enum.map(triples, fn {topic, payload, publish_opts} ->
        sanitized = Sanitizer.github_payload(payload, Keyword.get(publish_opts, :actor))
        {topic, publish_fun.(topic, sanitized, publish_opts)}
      end)

    published = for {topic, {:ok, _id, _subscribers}} <- results, do: topic

    %{status: :published, published: published, results: results}
  end

  # The reconcilers that own label and CI events live in the orchestrator's
  # poll cycle. `Lifecycle.schedule_tick/2` cancels the pending timer before
  # arming a new one, so an extra `:run_poll_cycle` reschedules rather than
  # compounding — but a delivery burst would still spin the cycle, so nudges
  # are coalesced into one per debounce window.
  defp request_reconcile(hint, opts) do
    case Keyword.get(opts, :reconcile_fun) do
      fun when is_function(fun, 1) -> fun.(hint)
      _other -> nudge_orchestrator(Keyword.get(opts, :orchestrator, Aiur.Orchestrator))
    end
  end

  defp nudge_orchestrator(target) do
    case resolve_orchestrator(target) do
      pid when is_pid(pid) ->
        if claim_reconcile_window() do
          send(pid, :run_poll_cycle)
          :ok
        else
          :coalesced
        end

      nil ->
        :ok
    end
  end

  defp resolve_orchestrator(pid) when is_pid(pid), do: pid
  defp resolve_orchestrator(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_orchestrator(_target), do: nil

  @doc false
  @spec reset_reconcile_window() :: :ok
  def reset_reconcile_window do
    :persistent_term.erase({__MODULE__, :last_reconcile_ms})
    :ok
  end

  defp claim_reconcile_window do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get({__MODULE__, :last_reconcile_ms}, nil)

    if is_integer(last) and now - last < @reconcile_debounce_ms do
      false
    else
      :persistent_term.put({__MODULE__, :last_reconcile_ms}, now)
      true
    end
  end
end
