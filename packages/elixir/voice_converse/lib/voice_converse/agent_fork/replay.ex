defmodule VoiceConverse.AgentFork.Replay do
  @moduledoc """
  Fallback for harnesses without a verified read-only fork: one call to the host's
  `:replay_model` with the briefing, the read-only note and the question. The answer comes from
  a summary, not the agent's own memory, so it carries `mode: :replay`. Without a model there is
  no replay: `{:error, :none}`, and nothing is started.
  """

  @behaviour VoiceConverse.AgentFork

  alias VoiceConverse.AgentFork

  @impl true
  def mode, do: :replay

  @impl true
  def preflight(_handle, opts) do
    if is_function(Keyword.get(opts, :replay_model), 1), do: :ok, else: {:error, :none}
  end

  @doc "The replay model's prompt."
  @spec prompt(String.t(), String.t() | nil) :: String.t()
  def prompt(question, briefing) do
    """
    #{AgentFork.read_only_note()}

    You do not have the agent's session, only this briefing about it:

    #{briefing || "(no briefing)"}

    Question: #{question}
    """
  end

  @impl true
  def run(_handle, question, ctx) do
    model = Keyword.fetch!(ctx.opts, :replay_model)
    prompt = prompt(question, Keyword.get(ctx.opts, :briefing))
    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> call(model, prompt) end)
    remaining = max(ctx.deadline - started, 0)

    case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, text}} ->
        {:ok, text, %{duration_ms: System.monotonic_time(:millisecond) - started}}

      {:ok, {:ok, text, usage}} ->
        {:ok, text, Map.put(usage, :duration_ms, System.monotonic_time(:millisecond) - started)}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:bad_replay_result, other}}

      nil ->
        {:error, :timeout}
    end
  end

  # A crashing model must not take the worker down with it (the task is linked).
  defp call(model, prompt) do
    model.(prompt)
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:crashed, {kind, reason}}}
  end
end
