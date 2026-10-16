defmodule Aiur.ExecutorAttention.DecisionEscalation do
  @moduledoc """
  Keeps an open blocking Decision from waiting in silence (#4567).

  `Aiur.ExecutorListener` wakes the Executor when the Decision is created and
  drives this ladder on a timer. While it stays open, the ladder re-wakes the Executor at 15 and 30 minutes and
  raises an operator alert at 45 minutes, then every hour. A Decision that
  gates 10 or more open tickets reaches the operator at 15 minutes.

  The ladder is a function of Decision age, so a restart resumes it instead of
  starting it again. The operator alert uses the Decision's durable
  `decision-stale` attention topic: a restart reads that topic to avoid a
  second alert, and the Commands component resolves it once the Decision is
  answered. All inputs are local state; nothing here calls GitHub.
  """

  alias Aiur.{AlertFeed, Commands, Decision, ExecutorWakeInbox, ExecutorWakeProjection, Signal}
  alias Aiur.BuildQueue.Hints
  alias Aiur.Events.Sanitizer

  @rewake_minutes [15, 30]
  @operator_minutes 45
  @urgent_operator_minutes 15
  @urgent_gates 10
  @repeat_minutes 60
  @attention_seconds 15 * 60

  @type entry :: %{wake: non_neg_integer(), operator: non_neg_integer(), woke_at: DateTime.t() | nil}

  @doc "The wake record for a Decision. Agent text is sanitized and listed in `untrusted_fields`."
  @spec wake_record(String.t(), String.t(), term(), term(), keyword()) :: map()
  def wake_record(ticket, decision_id, question, recommendation, opts \\ []) do
    topic = "ticket.#{ticket}.agent.attention.operator-decision"
    {:ok, record} = ExecutorWakeProjection.project(%{"topic" => topic, "id" => Keyword.get(opts, :event_id), "needs_attention" => true})

    Map.merge(record, %{
      "decision_id" => decision_id,
      "question" => untrusted(question, 200),
      "recommendation" => untrusted(option_id(recommendation), 64),
      "gates" => Keyword.get_lazy(opts, :gates, fn -> gates(ticket) end),
      "escalation" => Keyword.get(opts, :escalation, "created"),
      "untrusted_fields" => ["question", "recommendation"]
    })
  end

  @doc "Open dependents this ticket gates, from the local build-queue hints (0 without a queue)."
  @spec gates(String.t()) :: non_neg_integer()
  def gates(identifier) do
    {rank, _position} = Hints.sort_key(identifier)
    max(-rank, 0)
  end

  @doc "Ladder position for an age: `{executor re-wakes due, operator alerts due}`."
  @spec stage(integer(), non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def stage(age_seconds, gates) do
    minutes = div(max(age_seconds, 0), 60)
    first = if gates >= @urgent_gates, do: @urgent_operator_minutes, else: @operator_minutes
    operator = if minutes >= first, do: 1 + div(minutes - first, @repeat_minutes), else: 0
    {Enum.count(@rewake_minutes, &(minutes >= &1)), operator}
  end

  @doc "Open blocking Decisions, oldest first."
  @spec open_blocking([Decision.t()]) :: [Decision.t()]
  def open_blocking(decisions) do
    decisions
    |> Enum.filter(&(&1.blocking and &1.decision_status == :open))
    |> Enum.sort_by(&DateTime.to_unix(&1.created_at, :microsecond))
  end

  @doc """
  Advances the ladder for every open blocking Decision and returns the new
  per-Decision state. A Decision that is no longer open drops out, which
  clears its escalation.
  """
  @spec run(%{String.t() => entry()}, keyword()) :: %{String.t() => entry()}
  def run(fired, opts \\ []) do
    case decisions(opts) do
      {:ok, decisions} -> escalate(open_blocking(decisions), fired, opts)
      {:error, _reason} -> fired
    end
  end

  @doc """
  The `executor-wait` backstop: catches the ladder up, then wakes for every
  open blocking Decision older than 15 minutes that no wake surfaced in the
  last 15 minutes. It needs no backing event.
  """
  @spec backstop(%{String.t() => entry()}, keyword()) :: %{String.t() => entry()}
  def backstop(fired, opts \\ []) do
    case decisions(opts) do
      {:ok, decisions} -> surface(open_blocking(decisions), fired, opts)
      {:error, _reason} -> fired
    end
  end

  defp surface(open, fired, opts) do
    now = now(opts)
    fired = escalate(open, fired, opts)

    Enum.reduce(open, fired, fn decision, acc ->
      entry = Map.fetch!(acc, decision.decision_id)

      if aged?(decision, now) and stale_wake?(entry, now) do
        :ok = wake(decision, "backstop", opts)
        Map.put(acc, decision.decision_id, %{entry | woke_at: now})
      else
        acc
      end
    end)
  end

  @doc "`DECISIONS open N oldest <age> (#ticket, gates M)`; marked ATTENTION past 15 minutes."
  @spec status_line([Decision.t()], DateTime.t(), (String.t() -> non_neg_integer())) :: String.t()
  def status_line(decisions, now, gates_fun \\ &gates/1) do
    case open_blocking(decisions) do
      [] ->
        "DECISIONS open 0"

      [oldest | _] = open ->
        ticket = oldest.ticket.identifier
        line = "DECISIONS open #{length(open)} oldest #{age_label(age(oldest, now))} (##{ticket}, gates #{gates_fun.(ticket)})"
        if aged?(oldest, now), do: line <> " ATTENTION (answer with `aiur commands`)", else: line
    end
  end

  @doc "Prints the status line from the local DecisionStore."
  @spec print_status() :: :ok
  def print_status do
    IO.puts(status_line(Commands.list_decisions(), DateTime.utc_now()))
  catch
    :exit, _reason -> IO.puts("DECISIONS unavailable (the decision store could not be read)")
  end

  defp escalate(open, fired, opts) do
    now = now(opts)
    gates_fun = Keyword.get(opts, :gates_fun, &gates/1)
    states = open |> Enum.reject(&Map.has_key?(fired, &1.decision_id)) |> Enum.map(&operator_topic/1) |> condition_states(opts)

    Map.new(open, fn decision ->
      gates = gates_fun.(decision.ticket.identifier)
      {wake_due, operator_due} = stage(age(decision, now), gates)
      previous = Map.get(fired, decision.decision_id) || boot_entry(decision, states, operator_due)
      operator? = operator_due > previous.operator
      wake? = operator? or wake_due > previous.wake

      if operator?, do: alert(decision, now, gates, opts)
      if wake?, do: :ok = wake(decision, "rewake", Keyword.put(opts, :gates, gates))

      {decision.decision_id,
       %{
         wake: max(wake_due, previous.wake),
         operator: max(operator_due, previous.operator),
         woke_at: if(wake?, do: now, else: previous.woke_at)
       }}
    end)
  end

  # First sight of a Decision (a new one, or every open one after a restart).
  # A still-firing operator alert counts as delivered for the current stage,
  # so a restart does not alert the operator twice.
  defp boot_entry(decision, states, operator_due) do
    operator = if Map.get(states, operator_topic(decision)) == :firing, do: operator_due, else: 0
    %{wake: 0, operator: operator, woke_at: nil}
  end

  defp wake(decision, escalation, opts) do
    record =
      wake_record(decision.ticket.identifier, decision.decision_id, decision.question, decision.recommendation,
        escalation: escalation,
        gates: Keyword.get_lazy(opts, :gates, fn -> Keyword.get(opts, :gates_fun, &gates/1).(decision.ticket.identifier) end)
      )

    case Keyword.get(opts, :wake_fun) do
      fun when is_function(fun, 1) -> fun.(record)
      nil -> if Process.whereis(ExecutorWakeInbox), do: ExecutorWakeInbox.enqueue(record)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp alert(decision, now, gates, opts) do
    ticket = decision.ticket.identifier

    Keyword.get(opts, :alert_fun, &Signal.alert/2).(operator_topic(decision),
      issue: ticket,
      message: "Blocking decision #{decision.decision_id} on ##{ticket} is unanswered after #{age_label(age(decision, now))} (gates #{gates}).",
      reason: "An open blocking decision stops its ticket and every ticket it gates; answer it with `aiur commands`.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end

  defp operator_topic(decision), do: Commands.decision_stale_topic(decision)

  defp condition_states([], _opts), do: %{}
  defp condition_states(topics, opts), do: Keyword.get(opts, :condition_states_fun, &AlertFeed.condition_states/1).(topics)

  defp decisions(opts) do
    case Keyword.get(opts, :decisions_fun) do
      fun when is_function(fun, 0) -> fun.()
      nil -> {:ok, Commands.list_decisions()}
    end
  catch
    :exit, reason -> {:error, {:decision_store_unavailable, reason}}
  end

  defp aged?(decision, now), do: age(decision, now) > @attention_seconds
  defp stale_wake?(%{woke_at: nil}, _now), do: true
  defp stale_wake?(%{woke_at: woke_at}, now), do: DateTime.diff(now, woke_at) >= @attention_seconds

  defp age(decision, now), do: max(DateTime.diff(now, decision.created_at), 0)
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp age_label(seconds) when seconds >= 3_600, do: "#{div(seconds, 3_600)}h#{div(rem(seconds, 3_600), 60)}m"
  defp age_label(seconds), do: "#{div(seconds, 60)}m"

  defp option_id(%{option_id: id}), do: id
  defp option_id(%{"option_id" => id}), do: id
  defp option_id(_recommendation), do: nil

  defp untrusted(text, limit) when is_binary(text), do: text |> Sanitizer.strip_untrusted_text() |> String.slice(0, limit)
  defp untrusted(_text, _limit), do: nil
end
