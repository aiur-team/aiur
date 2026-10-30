defmodule Aiur.VoiceConverse.Host.CommandSource do
  @moduledoc "Read-only worker Commands. Answer delivery is not part of this host adapter."
  @behaviour VoiceConverse.Ports.CommandSource

  alias Aiur.Commands
  alias Aiur.VoiceConverse.Host.Worker

  @impl true
  def open(target), do: open(target, [])

  @spec open(term(), keyword()) :: {:ok, [VoiceConverse.Ports.CommandSource.command()]} | {:error, :unavailable}
  def open(%Worker{identity: identity}, opts) do
    commands =
      opts
      |> Keyword.get(:decision_store, Commands.default_store())
      |> Commands.list_decisions(2_000)
      |> Enum.filter(&(&1.ticket.identifier == identity.identifier and &1.decision_status in [:open, :deferred]))
      |> Enum.map(&%{id: &1.decision_id, version: &1.version, question: &1.question, options: &1.options})

    {:ok, commands}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def open(_target, _opts), do: {:error, :unavailable}

  @impl true
  def answer(_target, _id, _choice, _idempotency_key), do: {:error, :unsupported}

  @impl true
  def subscribe(target, pid), do: subscribe(target, pid, [])

  @doc false
  @spec subscribe(term(), pid(), keyword()) :: :ok | :unsupported
  def subscribe(target, pid, opts), do: Aiur.VoiceConverse.Host.LiveContext.subscribe(target, pid, :commands, opts)
end
