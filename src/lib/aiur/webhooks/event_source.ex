defmodule Aiur.Webhooks.EventSource do
  @moduledoc """
  The two ways a repo's events reach the bus, behind one identical interface.

  Consumers — agents, the orchestrator, every subscriber — must be unable to
  tell which mode a repo is in. That is only enforceable if both transports
  hand the bus the *same* event, so both are expressed as implementations of
  this one callback and neither is allowed a payload shape of its own.

  `Aiur.Webhooks.EventSource.Polling` is what happens today: publish the
  normalized event. `Aiur.Webhooks.EventSource.Webhook` does exactly that and,
  additionally, records the delivery so the repo stays proven and its silence
  timer stays alive. The extra bookkeeping is invisible downstream — that
  difference, and only that difference, is what makes webhook mode an
  enhancement rather than a second code path.

  The equivalence contract is enforced by a shared consumer suite that runs
  every consumer test against both implementations unchanged.
  """

  alias Aiur.Events.Exchange

  @typedoc "Normalized event published onto the bus, identical across transports."
  @type event :: %{topic: String.t(), payload: map()}

  @doc """
  Publishes one normalized event for `repo` and returns what was published.

  Options are implementation-shared:

    * `:publish_fun` — 1-arity sink for the normalized event (test injection;
      defaults to the exchange publish path)
    * `:at` — delivery timestamp, for the webhook implementation's proof
    * `:server` — mode registry, for the webhook implementation's proof
  """
  @callback deliver(repo :: String.t(), event(), opts :: keyword()) :: {:ok, event()}

  @doc "The source module for a transport."
  @spec for_transport(:polling | :webhook) :: module()
  def for_transport(:webhook), do: __MODULE__.Webhook
  def for_transport(:polling), do: __MODULE__.Polling

  @doc """
  Publishes the normalized event through the shared sink.

  Both implementations funnel through here, so there is exactly one place a
  transport-specific payload could ever be introduced — and it takes the event
  already built, so there isn't one.
  """
  @spec publish(event(), keyword()) :: {:ok, event()}
  def publish(%{topic: topic, payload: payload} = event, opts) do
    case Keyword.get(opts, :publish_fun) do
      fun when is_function(fun, 1) -> fun.(event)
      _default -> Exchange.publish(topic, payload)
    end

    {:ok, event}
  end
end
