defmodule Aiur.DecisionPremises do
  @moduledoc """
  Flags open tickets built on a Command answer that has since changed.

  A ticket names the decisions it depends on with a body line
  `Premises: dec_1, dec_2` (same shape as `Skills:`). When one of those
  decisions is revised, superseded or mooted, each open dependent ticket gets
  the `<prefix>:premise-changed` marker label, the Executor gets a wake naming
  the ticket, decision, old answer and new answer (or moot reason), and a
  running worker on the ticket gets the same text as an operator message. The
  Executor removes the label once it has reviewed the ticket.
  """

  require Logger

  alias Aiur.{Config, DecisionAnswer, ExecutorWakeProjection, ExecutorWakeInbox, Tracker}
  alias Aiur.GitHub.Labels
  alias Aiur.GitHub.Config, as: GitHubConfig

  @type change :: %{
          required(:decision_id) => String.t(),
          required(:kind) => :revised | :mooted,
          required(:old_answer) => String.t() | nil,
          optional(:new_answer) => String.t() | nil,
          optional(:moot_reason) => String.t() | nil
        }

  @doc "Decision ids named on the first `Premises:` line outside a code fence."
  @spec premises(term()) :: [String.t()]
  def premises(%{description: body}), do: premises(body)

  def premises(body) when is_binary(body) do
    body
    |> Aiur.IssueBody.lines()
    |> Enum.find_value([], fn line ->
      case Regex.run(~r/\A\s*Premises:\s*(.+)\z/i, line) do
        [_, ids] -> ids |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        _no_match -> nil
      end
    end)
  end

  def premises(_issue), do: []

  @doc "Short human form of an answer, for wakes and worker messages."
  @spec answer_text(DecisionAnswer.t() | nil) :: String.t() | nil
  def answer_text(%DecisionAnswer{rejected: true}), do: "rejected"
  def answer_text(%DecisionAnswer{selected_option_id: id, custom_response: custom}) when is_binary(id) and is_binary(custom), do: "#{id}: #{custom}"
  def answer_text(%DecisionAnswer{selected_option_id: id}) when is_binary(id), do: id
  def answer_text(%DecisionAnswer{custom_response: custom}) when is_binary(custom), do: custom
  def answer_text(_answer), do: nil

  @doc "Runs `flag/2` off the caller's process; the decision store must not block on tracker IO."
  @spec notify_async(change()) :: :ok
  def notify_async(change) do
    if Process.whereis(Aiur.TaskSupervisor), do: Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> flag(change) end)
    :ok
  end

  @doc """
  Labels, wakes and messages for every open dependent ticket. Returns the
  identifiers flagged. Dependencies are injectable through `opts` for tests.
  """
  @spec flag(change(), keyword()) :: [String.t()]
  def flag(%{decision_id: decision_id} = change, opts \\ []) do
    fetch = Keyword.get(opts, :fetch_issues, &fetch_open_issues/0)
    add_label = Keyword.get(opts, :add_label, &Tracker.add_label/2)
    wake = Keyword.get(opts, :wake, &enqueue_wake/1)
    message = Keyword.get(opts, :message_worker, &message_worker/2)
    label = Keyword.get_lazy(opts, :label, &label/0)
    terminal = Keyword.get_lazy(opts, :terminal_states, &terminal_states/0)

    case fetch.() do
      {:ok, issues} ->
        issues
        |> Enum.reject(&(state_slug(&1.state) in terminal))
        |> Enum.filter(&(decision_id in premises(&1)))
        |> Enum.uniq_by(& &1.identifier)
        |> Enum.flat_map(&flag_issue(&1, change, label, add_label, wake, message))

      {:error, reason} ->
        Logger.warning("premise check for #{decision_id} could not list open tickets: #{inspect(reason)}")
        []
    end
  rescue
    error ->
      Logger.warning("premise check for #{change[:decision_id]} failed: #{Exception.message(error)}")
      []
  end

  defp flag_issue(issue, change, label, add_label, wake, message) do
    case add_label.(issue.id, label) do
      :ok ->
        wake.(wake_record(issue.identifier, change))
        message.(issue.identifier, worker_text(issue.identifier, change))
        [issue.identifier]

      {:error, reason} ->
        Logger.warning("could not label ##{issue.identifier} #{label}: #{inspect(reason)}")
        []
    end
  end

  @doc "Executor wake for one flagged ticket."
  @spec wake_record(String.t(), change()) :: map()
  def wake_record(ticket, change) do
    topic = "ticket.#{ticket}.agent.attention.premise-changed"
    {:ok, record} = ExecutorWakeProjection.project(%{"topic" => topic, "needs_attention" => true})

    Map.merge(record, %{
      "decision_id" => change.decision_id,
      "premise_change" => Atom.to_string(change.kind),
      "old_answer" => change[:old_answer],
      "new_answer" => change[:new_answer],
      "moot_reason" => change[:moot_reason],
      "untrusted_fields" => ["old_answer", "new_answer", "moot_reason"]
    })
  end

  @doc "Operator message text for a worker on a flagged ticket."
  @spec worker_text(String.t(), change()) :: String.t()
  def worker_text(ticket, %{kind: :mooted} = change) do
    "Premise changed for ##{ticket}: decision #{change.decision_id} was mooted (#{change[:moot_reason] || "no reason given"}). " <>
      "Its answer #{quote_answer(change.old_answer)} no longer holds. Stop building on it and check with the Executor."
  end

  def worker_text(ticket, change) do
    "Premise changed for ##{ticket}: decision #{change.decision_id} changed from #{quote_answer(change.old_answer)} " <>
      "to #{quote_answer(change[:new_answer])}. Re-check your work against the new answer."
  end

  defp quote_answer(nil), do: "(no answer)"
  defp quote_answer(text), do: inspect(text)

  defp enqueue_wake(record) do
    if Process.whereis(ExecutorWakeInbox), do: ExecutorWakeInbox.enqueue(record)
    :ok
  catch
    :exit, _reason -> :ok
  end

  # No running worker is the common case; the label and wake still stand.
  defp message_worker(ticket, text) do
    Aiur.Orchestrator.send_operator_message(ticket, %{kind: :text, body: text})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp label, do: "#{GitHubConfig.label_prefix()}:#{Labels.premise_changed_suffix()}"

  # ponytail: lists issues carrying a non-terminal agent state label; an open
  # ticket with no agent:* label is not checked.
  defp fetch_open_issues do
    states = Labels.state_suffixes() -- terminal_states()
    Tracker.fetch_issues_by_states(states, quiet_auth_errors?: true)
  end

  defp terminal_states, do: Enum.map(Config.settings!().tracker.terminal_states, &state_slug/1)

  defp state_slug(state) when is_binary(state), do: Aiur.Orchestrator.DispatchPolicy.state_slug(state)
  defp state_slug(_state), do: nil
end
