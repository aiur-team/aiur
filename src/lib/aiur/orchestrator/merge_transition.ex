defmodule Aiur.Orchestrator.MergeTransition do
  @moduledoc false

  alias Aiur.GitHub.{Config, IssueState}
  alias Aiur.GitHub.Errors, as: GitHubErrors
  alias Aiur.GitHub.LocalHold

  @terminal_write_attempts 3

  @spec normalize(term()) :: term()
  def normalize({_target, {:error, {:no_state_label_written, issue}}} = outcome)
      when is_map(issue) do
    if closed_done?(issue), do: {"done", :ok}, else: outcome
  end

  def normalize(outcome), do: outcome

  @spec retry_terminal_write((-> term()), keyword(), pos_integer()) :: term()
  def retry_terminal_write(write_fun, opts, attempt \\ 1)

  def retry_terminal_write(write_fun, opts, attempt) do
    case write_fun.() do
      {:error, reason} = error when attempt < @terminal_write_attempts ->
        if retryable_terminal_write_error?(reason) do
          sleep_fun = Keyword.get(opts, :merge_terminal_write_sleep_fun, &Process.sleep/1)
          sleep_fun.(100 * attempt)
          retry_terminal_write(write_fun, opts, attempt + 1)
        else
          error
        end

      result ->
        result
    end
  end

  # Local holds and rate limits already have retry/wait behavior at the GitHub
  # request boundary. Replaying a whole label swap here can multiply reads and
  # writes while the same budget hold is still active.
  defp retryable_terminal_write_error?({:github, kind, _detail})
       when kind in [:local_hold, :rate_limited], do: false

  defp retryable_terminal_write_error?(reason), do: GitHubErrors.retryable_github_error?(reason)

  @spec write_terminal_target(
          term(),
          String.t() | integer(),
          (String.t(), String.t() -> term()),
          keyword()
        ) :: term()
  def write_terminal_target("done", identifier, update_issue_state_fun, opts) do
    LocalHold.run(
      fn ->
        retry_terminal_write(
          fn -> update_issue_state_fun.(to_string(identifier), "done") end,
          opts
        )
      end,
      LocalHold.caller_opts(Keyword.put(opts, :local_hold_max_wait_ms, 3_600_000))
    )
  end

  def write_terminal_target(target, identifier, update_issue_state_fun, opts)
      when target in ["rework", "ci-wait", "human-review"] do
    retry_terminal_write(fn -> update_issue_state_fun.(to_string(identifier), target) end, opts)
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
