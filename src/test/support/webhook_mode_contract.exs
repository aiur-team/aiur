defmodule Aiur.WebhookModeContract do
  @moduledoc """
  Shared harness that runs one consumer test body against **both** delivery
  modes.

  The realistic long-term failure for this epic is not a bug — it is decay.
  Webhook mode becomes the tested path, polling quietly rots, and the first
  repo without a webhook hits a bug nobody can see because every CI run and
  every dev fleet uses webhooks. A convention ("please cover both") does not
  survive that; a harness does.

  So a consumer test does not choose a mode. It calls `mode_test/2`, which
  emits one ExUnit test per mode from the same body, and reaches the bus only
  through `deliver/3`, which routes through the real `EventSource` for whatever
  mode the generated test is running. There is no way to express a one-mode
  consumer test through this API, and `webhook_consumer_contract_test.exs`
  fails the build if a consumer test file tries to bypass it with a bare
  `test/2`.

  ## Usage

      defmodule Aiur.Webhooks.ConsumerFooTest do
        use ExUnit.Case, async: true
        use Aiur.WebhookModeContract

        mode_test "delivers the same event", ctx do
          {:ok, event} = deliver(ctx, "ticket.7.pr.opened", %{number: 7})
          assert event.payload == %{number: 7}
        end
      end
  """

  alias Aiur.Webhooks.{EventSource, ModeRegistry}

  @modes [:polling, :webhook]

  @doc "Every mode a consumer test is generated for."
  def modes, do: @modes

  defmacro __using__(_opts) do
    quote do
      import Aiur.WebhookModeContract, only: [mode_test: 3, deliver: 3, deliver: 4]
    end
  end

  @doc """
  Defines the same test once per delivery mode.

  The body receives a context whose `:mode` is the mode under test and whose
  `:repo` is a per-mode repo already registered in that mode. The body must not
  branch on `ctx.mode` — that is precisely the branching the contract forbids.
  """
  defmacro mode_test(name, context, do: block) do
    for mode <- @modes do
      quote do
        test "#{unquote(name)} [#{unquote(mode)} mode]" do
          unquote(context) = Aiur.WebhookModeContract.start_mode!(unquote(mode))
          unquote(block)
        end
      end
    end
  end

  @doc """
  Starts an isolated mode registry and returns the consumer test context.

  Each generated test gets its own registry and its own repo name, so the two
  modes cannot leak state into each other and the suite stays `async: true`.
  """
  def start_mode!(mode) do
    name = :"webhook_mode_registry_#{mode}_#{System.unique_integer([:positive])}"
    repo = "aiur-team/#{mode}-repo-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ModeRegistry.start_link(
        name: name,
        configured_repos: configured_repos(mode, repo),
        silence_threshold_ms: 60_000,
        sweep_interval_ms: 60_000,
        alert_fun: fn _name, _message, _opts -> :ok end
      )

    ExUnit.Callbacks.on_exit(fn -> stop(pid) end)

    %{mode: mode, repo: repo, server: name, source: EventSource.for_transport(mode)}
  end

  # A polling repo is one with no webhook at all — the untouched default. The
  # webhook repo is only *configured* here; the delivery in the test body is
  # what proves it, exactly as in production.
  defp configured_repos(:webhook, repo), do: [repo]
  defp configured_repos(:polling, _repo), do: []

  @doc """
  Delivers one normalized event through the context's mode and returns it.

  Both modes go through the production `EventSource` implementation for that
  mode, so a consumer observing a difference here is observing a real one.
  """
  def deliver(context, topic, payload, opts \\ []) do
    event = %{topic: topic, payload: payload}

    opts =
      opts
      |> Keyword.put_new(:server, context.server)
      |> Keyword.put_new(:publish_fun, fn published -> send(self(), {:published, published}) end)

    context.source.deliver(context.repo, event, opts)
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
