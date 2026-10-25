defmodule Aiur.Orchestrator.MergeTransition do
  @moduledoc false

  alias Aiur.GitHub.{Config, IssueState}
  alias Aiur.GitHub.Errors, as: GitHubErrors
  alias Aiur.GitHub.LocalHold
  alias Aiur.Orchestrator.TicketTransition

  @terminal_write_attempts 3

  @spec normalize(term()) :: term()
  def normalize({_target, {:error, {:no_state_label_written, issue}}} = outcome)
      when is_map(issue) do
    if closed_done?(issue), do: {"done", :ok}, else: outcome
  end

  def normalize(outcome), do: outcome

  @spec retry_terminal_write((-> term()), keyword(), pos_integer()) :: term()
  def retry_terminal_write(write_fun, opts, attempt \\ 1)

  def retry_terminal_write(write_fun, opts, attempt),
    do: retry_terminal_write(write_fun, opts, attempt, false)

  defp retry_terminal_write(write_fun, opts, attempt, retry_local_hold?) do
    case write_fun.() do
      {:error, reason} = error when attempt < @terminal_write_attempts ->
        if retryable_terminal_write_error?(reason, retry_local_hold?) do
          sleep_fun = Keyword.get(opts, :merge_terminal_write_sleep_fun, &Process.sleep/1)
          sleep_fun.(100 * attempt)
          retry_terminal_write(write_fun, opts, attempt + 1, retry_local_hold?)
        else
          error
        end

      result ->
        result
    end
  end

  # Rate limits already have retry/wait behavior at the GitHub request
  # boundary. Local holds are waited out to reset_at by LocalHold for terminal
  # writes, even when they exceed its ordinary wait ceiling.
  defp retryable_terminal_write_error?({:github, :local_hold, _detail}, true), do: true

  defp retryable_terminal_write_error?({:github, kind, _detail}, _retry_local_hold?)
       when kind in [:local_hold, :rate_limited], do: false

  defp retryable_terminal_write_error?(reason, _retry_local_hold?), do: GitHubErrors.retryable_github_error?(reason)

  @spec write_terminal_target(
          term(),
          String.t() | integer(),
          (String.t(), String.t() -> term()),
          keyword()
        ) :: term()
  def write_terminal_target("done", identifier, update_issue_state_fun, opts) do
    retry_terminal_write(
      fn ->
        LocalHold.run(
          fn -> update_issue_state_fun.(to_string(identifier), "done") end,
          LocalHold.caller_opts(
            opts
            |> Keyword.put(:local_hold_max_wait_ms, 3_600_000)
            |> Keyword.put(:local_hold_wait_for_reset, true)
          )
        )
      end,
      opts,
      1,
      true
    )
  end

  def write_terminal_target(target, identifier, update_issue_state_fun, opts)
      when target in ["rework", "ci-wait", "human-review"] do
    retry_terminal_write(fn -> update_issue_state_fun.(to_string(identifier), target) end, opts)
  end

  def write_terminal_target("needs-triage", identifier, update_issue_state_fun, opts) do
    identifier = to_string(identifier)
    marker = Keyword.get(opts, :non_closing_merge_marker, Aiur.Config.settings!().agent.non_closing_merge_marker || "needs-triage")
    add_marker = Keyword.get(opts, :add_label_fun, fn id, label -> TicketTransition.write_marker(id, :add, label, writer: :comment_wake) end)
    comment = Keyword.get(opts, :create_comment_fun, fn id, body -> TicketTransition.write_comment(id, body, writer: :comment_wake) end)
    number = Keyword.get(opts, :pr_number, "unknown")
    url = Keyword.get(opts, :pr_url, "")

    with :ok <- add_marker.(identifier, marker),
         :ok <- update_issue_state_fun.(identifier, "human-review") do
      comment.(identifier, "Merged PR ##{number} (#{url}) references this ticket without a closing keyword; moved to human-review with `#{marker}` for triage.")
    end
  end

  def write_terminal_target({:error, _} = error, _identifier, _update_issue_state_fun, _opts),
    do: error

  @spec reason_name(term()) :: atom()
  def reason_name({:github, classification, _detail}) when is_atom(classification),
    do: classification

  def reason_name(reason) when is_atom(reason), do: reason

  def reason_name(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: reason_name(elem(reason, 0))

  def reason_name(_reason), do: :unknown

  defp closed_done?(issue) do
    prefix = Config.label_prefix()

    states =
      issue
      |> Map.get("labels", [])
      |> Enum.map(&Map.get(&1, "name", ""))
      |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
      |> Enum.reject(&IssueState.preserved_prefixed_label?(&1, prefix))

    IssueState.closed_issue?(issue) and states == ["#{prefix}:done"]
  end
end
