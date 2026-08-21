defmodule Aiur.Webhooks do
  @moduledoc """
  Default-safe facade over per-repo webhook delivery mode.

  Every function here answers as though the repo were a plain polling repo when
  the registry is not running, is still booting, or has never heard of the repo.
  That is deliberate: polling is a complete, supported mode, and a repo with no
  webhook must behave exactly as it did before this module existed. Callers
  therefore never need a `case` on whether webhooks are available.

  Consumers of events must not call anything in this module to decide *behavior*.
  Transport is invisible by contract; the functions here exist for interval
  policy and for showing an operator what is going on.
  """

  alias Aiur.Webhooks.{DeliveryMode, ModeRegistry}

  @doc """
  Records one observed, verified webhook delivery for `repo`.

  This is the seam the webhook receiver calls. Returns `:ok` even when no
  registry is running so the receiver never has to care.
  """
  @spec record_delivery(String.t(), keyword()) :: :ok
  def record_delivery(repo, opts \\ []) when is_binary(repo) do
    safely(fn -> ModeRegistry.record_delivery(repo, opts) end, {:ok, nil})
    :ok
  end

  @doc """
  Records that the poller observed repository activity for `repo`.

  Corroboration for the silence sweep, never proof of a working webhook. Safe
  to call unconditionally: it returns `:ok` even when no registry is running.

  Fire-and-forget, because the caller is the event publish path and an alert
  that fires on a 60s sweep must never put a registry round trip on it.
  """
  @spec record_activity(String.t(), keyword()) :: :ok
  def record_activity(repo, opts \\ []) when is_binary(repo) do
    safely(fn -> ModeRegistry.record_activity_async(repo, opts) end, :ok)
    :ok
  end

  @doc "Current mode for `repo`, defaulting to a never-configured polling repo."
  @spec mode(String.t(), keyword()) :: DeliveryMode.t()
  def mode(repo, opts \\ []) when is_binary(repo) do
    server = Keyword.get(opts, :server, ModeRegistry)
    safely(fn -> ModeRegistry.mode(repo, server) end, DeliveryMode.new(repo))
  end

  @doc "Transport serving `repo`. Always `:polling` unless the repo is proven."
  @spec transport(String.t(), keyword()) :: DeliveryMode.transport()
  def transport(repo, opts \\ []) when is_binary(repo) do
    repo |> mode(opts) |> DeliveryMode.transport()
  end

  @doc "True only for a repo proven webhook-backed and not currently degraded."
  @spec webhook_backed?(String.t(), keyword()) :: boolean()
  def webhook_backed?(repo, opts \\ []) when is_binary(repo), do: transport(repo, opts) == :webhook

  @doc "Why `repo` is polling, or `nil` when it is webhook-backed."
  @spec polling_reason(String.t(), keyword()) :: DeliveryMode.polling_reason()
  def polling_reason(repo, opts \\ []) when is_binary(repo) do
    repo |> mode(opts) |> DeliveryMode.polling_reason()
  end

  @doc "Every known repo's mode; empty when no registry is running."
  @spec list(keyword()) :: [DeliveryMode.t()]
  def list(opts \\ []) do
    server = Keyword.get(opts, :server, ModeRegistry)
    safely(fn -> ModeRegistry.list(server) end, [])
  end

  # A missing or restarting registry must read as "polling", never as an error
  # and never as a crash in the caller's process.
  defp safely(fun, fallback) do
    fun.()
  catch
    :exit, _reason -> fallback
  end
end
