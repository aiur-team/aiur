defmodule Aiur.VoiceConverse.Host.BriefingSource do
  @moduledoc """
  Aiur worker status and conversation reads for provider context. Executor reads
  retain the existing prototype. Port deadlines are enforced by VoiceConverse.
  """
  @behaviour VoiceConverse.Ports.BriefingSource

  alias Aiur.Orchestrator.StatusReport
  alias Aiur.TrackerIdentity
  alias Aiur.VoiceConversation.BriefingSource, as: Executor
  alias Aiur.VoiceConverse.Host.{Conversation, Worker}
  alias VoiceConverse.Briefing

  @impl true
  def describe_target(:executor), do: Executor.describe_target(:executor)

  def describe_target(%Worker{identity: identity}),
    do: %{id: identity.identifier, kind: :worker, title: "Worker #{identity.identifier}"}

  @impl true
  def brief(target), do: brief(target, [])

  @spec brief(Worker.t() | :executor, keyword()) :: {:ok, Briefing.t()} | {:error, :unavailable}
  def brief(:executor, _opts), do: Executor.brief(:executor)

  def brief(%Worker{} = target, opts) do
    with {:ok, row} <- status(target, opts) do
      {:ok,
       %Briefing{
         summary: field(row[:state], row),
         current_task: field(row[:title], row),
         gaps: if(row[:observed_at], do: [], else: ["Status observation time unavailable."])
       }}
    end
  end

  @impl true
  def details(:executor, section, opts), do: Executor.details(:executor, section, opts)
  def details(%Worker{} = target, "conversation", opts), do: Conversation.read(target, opts)
  def details(%Worker{}, _section, _opts), do: {:error, :unavailable}

  @impl true
  def sections(:executor), do: Executor.sections(:executor)
  def sections(%Worker{}), do: [%{id: "conversation", description: "Recent worker conversation"}]

  @impl true
  def subscribe(_target, _pid), do: :unsupported

  @impl true
  def alive?(target), do: alive?(target, [])

  @spec alive?(Worker.t() | :executor, keyword()) :: boolean() | :unknown
  def alive?(:executor, _opts), do: Executor.alive?(:executor)

  def alive?(%Worker{} = target, opts) do
    case snapshot(opts) do
      %{running: rows} when is_list(rows) -> Enum.any?(rows, &matches?(&1, target))
      _ -> :unknown
    end
  end

  @doc false
  @spec status(Worker.t(), keyword()) :: {:ok, map()} | {:error, :unavailable}
  def status(%Worker{} = target, opts \\ []) do
    case snapshot(opts) do
      %{running: running, retrying: retrying, idle: idle} ->
        case Enum.find(running ++ retrying ++ idle, &matches?(&1, target)) do
          nil -> {:error, :unavailable}
          row -> {:ok, row}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp snapshot(opts) do
    StatusReport.snapshot_api(Keyword.get(opts, :orchestrator, Aiur.Orchestrator), 2_000)
  catch
    :exit, _ -> :unavailable
  end

  defp matches?(row, %Worker{identity: identity}) do
    key = TrackerIdentity.github_key(identity)
    key != nil and TrackerIdentity.github_key(row[:tracker_identity]) == key
  end

  defp field(nil, _row), do: nil
  defp field(value, row), do: %{value: value, observed_at: observed_at(row[:observed_at]), max_age_s: 30}
  defp observed_at(%DateTime{} = at), do: at

  defp observed_at(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp observed_at(_), do: nil
end
