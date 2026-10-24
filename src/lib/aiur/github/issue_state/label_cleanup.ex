defmodule Aiur.GitHub.IssueState.LabelCleanup do
  @moduledoc false

  alias Aiur.GitHub.{IssueState, StatePolicy}

  @spec remove_state_labels(function(), String.t(), String.t(), String.t(), String.t(), map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def remove_state_labels(request_fun, token, owner, repo, issue_number, issue_body, prefix, opts \\ []) do
    excluded = Keyword.get(opts, :exclude, []) |> Enum.map(&String.downcase/1)

    issue_body
    |> labels(prefix)
    |> Enum.reject(fn label ->
      (Keyword.get(opts, :clear_terminal_state_overrides, false) and StatePolicy.terminal_state_label?(label, prefix)) or
        (preserved?(label, prefix) and not clear_override?(opts, label, prefix)) or
        String.downcase(label) in excluded
    end)
    |> remove_labels(request_fun, token, owner, repo, issue_number)
  end

  @spec remove_active_state_labels(function(), String.t(), String.t(), String.t(), String.t(), map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def remove_active_state_labels(request_fun, token, owner, repo, issue_number, issue_body, prefix, opts \\ []) do
    issue_body
    |> labels(prefix)
    |> Enum.reject(fn label ->
      StatePolicy.terminal_state_label?(label, prefix) or
        (preserved?(label, prefix) and not clear_override?(opts, label, prefix))
    end)
    |> remove_labels(request_fun, token, owner, repo, issue_number)
  end

  defp labels(issue, prefix) do
    issue
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name", ""))
    |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
  end

  defp preserved?(label, prefix), do: IssueState.preserved_prefixed_label?(label, prefix)

  defp clear_override?(opts, label, prefix) do
    Keyword.get(opts, :clear_terminal_state_overrides, false) and
      String.downcase(label) in ["#{prefix}:parked", "#{prefix}:paused"]
  end

  defp remove_labels(labels, request_fun, token, owner, repo, issue_number) do
    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case IssueState.delete_issue_label(request_fun, token, owner, repo, issue_number, label) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
