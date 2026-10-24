# Cohesion: keep GitHub state-label swaps and their compensating writes together.
defmodule Aiur.GitHub.IssueState do
  @moduledoc """
  Label-encoded issue state writes for GitHub issues.

  This module owns issue state transitions implemented as GitHub label swaps,
  terminal-state closing, and raw per-issue label add/remove primitives. It
  preserves the closed-issue recheck before adding active labels so stale state
  removal cannot reopen or relabel a closed issue.
  """

  alias Aiur.GitHub.Config
  alias Aiur.GitHub.{Errors, HumanReviewGate, Issues, Labels, LocalHold, StatePolicy, Transport, WriteThrough}
  alias Aiur.GitHub.IssueState.ClosedIssue
  require Logger

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_number, state_name, opts \\ [])
      when is_binary(issue_number) and is_binary(state_name) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      prefix = Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      request_fun = retry_local_holds(request_fun, opts)
      issue_url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"

      update_context = %{
        request_fun: request_fun,
        token: token,
        issue_url: issue_url,
        owner: owner,
        repo: repo,
        issue_number: issue_number,
        prefix: prefix,
        opts: opts
      }

      do_update_issue_state(update_context, state_name)
    end
  end

  @spec add_label(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def add_label(issue_number, label, opts \\ [])
      when is_binary(issue_number) and is_binary(label) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels"

      case request_fun.(%{method: :post, url: url, token: token, body: %{"labels" => [label]}}) do
        {:ok, %{status: status, body: labels}} when status in 200..299 ->
          WriteThrough.issue_labels(issue_number, labels)
          :ok

        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  @spec remove_label(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove_label(issue_number, label, opts \\ [])
      when is_binary(issue_number) and is_binary(label) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"

      case request_fun.(%{method: :delete, url: url, token: token}) do
        # A removal answers with the labels that survived it, so the deposit is
        # the issue's whole truthful label set rather than a delta.
        {:ok, %{status: status, body: labels}} when status in 200..299 ->
          WriteThrough.issue_labels(issue_number, labels)
          :ok

        # 404 = label already absent; treat as success so the toggle is idempotent.
        {:ok, %{status: status}} when status in 200..299 or status == 404 ->
          :ok

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  @spec do_update_issue_state(map(), String.t()) :: :ok | {:error, term()}
  def do_update_issue_state(update_context, state_name) do
    new_label = StatePolicy.state_label(update_context.prefix, state_name)

    case Issues.fetch_issue_raw_conditional(update_context.issue_number, issue_read_opts(update_context)) do
      {:ok, issue_body, _outcome} ->
        apply_issue_state_update(update_context, issue_body, state_name, new_label)

      {:error, _reason} = error ->
        error
    end
  end

  @spec apply_issue_state_update(map(), map(), String.t(), String.t()) :: :ok | {:error, term()}
  def apply_issue_state_update(context, issue_body, state_name, new_label) do
    with :ok <- validate_expected_state(context, issue_body),
         :ok <- HumanReviewGate.verify_human_review_review_threads_clear(context, state_name),
         {:ok, current_issue_body} <- revalidate_expected_state(context, issue_body) do
      if closed_issue?(current_issue_body) and StatePolicy.active_target_state?(state_name) do
        handle_closed_active_target(context, current_issue_body)
      else
        swap_and_maybe_close_issue(context, current_issue_body, state_name, new_label)
      end
    end
  end

  defp handle_closed_active_target(context, current_issue_body) do
    ClosedIssue.apply(context, current_issue_body)
  end

  defp revalidate_expected_state(%{opts: opts} = context, issue_body) do
    if Keyword.has_key?(opts, :expected_state) do
      # The point of this second read is to be *sure* the state has not moved
      # since the first, so it must always contact GitHub — `revalidate: true`
      # skips the served-from-store path and sends the held ETag, which costs a
      # free `304` when nothing changed.
      case Issues.fetch_issue_raw_conditional(
             context.issue_number,
             guarded_issue_read_opts(context) |> Keyword.put(:revalidate, true)
           ) do
        {:ok, current_issue_body, _outcome} ->
          validate_revalidated_state(context, current_issue_body)

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, issue_body}
    end
  end

  defp validate_revalidated_state(context, current_issue_body) do
    case validate_expected_state(context, current_issue_body) do
      :ok -> {:ok, current_issue_body}
      {:error, _reason} = error -> error
    end
  end

  defp validate_expected_state(%{opts: opts, prefix: prefix}, issue_body) do
    case reject_held_labels(opts, issue_body) do
      :ok -> validate_state_precondition(opts, issue_body, prefix)
      {:error, _reason} = error -> error
    end
  end

  defp reject_held_labels(opts, issue_body) do
    held = Keyword.get(opts, :refuse_labels, []) |> Enum.map(&normalize_label_name/1)
    labels = issue_body |> Map.get("labels", []) |> Enum.map(&normalize_label_name(Map.get(&1, "name", "")))

    case Enum.find(held, &(&1 in labels)) do
      nil -> :ok
      label -> {:error, {:operator_hold, label}}
    end
  end

  defp validate_state_precondition(opts, issue_body, prefix) do
    case Keyword.fetch(opts, :expected_state) do
      :error ->
        :ok

      {:ok, :none} ->
        # This precondition concerns labels; closed issues still reach the closed-write guard.
        actual = current_state(Map.delete(issue_body, "state"), prefix)

        if actual == nil do
          :ok
        else
          {:error, {:stale_issue_state, :none, actual}}
        end

      {:ok, expected_state} when is_binary(expected_state) ->
        expected = StatePolicy.normalize_state(expected_state)
        actual = current_state(issue_body, prefix)

        if actual == expected do
          :ok
        else
          {:error, {:stale_issue_state, expected, actual}}
        end

      {:ok, _invalid} ->
        {:error, :invalid_expected_state}
    end
  end

  defp current_state(issue_body, prefix) do
    labels = issue_body |> Map.get("labels", []) |> Enum.map(&Map.get(&1, "name", ""))

    case Issues.extract_state(issue_body, labels, prefix) do
      state when is_binary(state) -> StatePolicy.normalize_state(state)
      nil -> nil
    end
  end

  @spec swap_labels(map(), map(), String.t(), String.t()) :: :ok | {:error, term()}
  def swap_labels(context, _issue_body, state_name, new_label) do
    # Add-first prevents a zero-label window; failures after add are rolled back.
    case add_state_label(context, state_name, new_label) do
      :ok ->
        case complete_label_swap(context, new_label) do
          :ok -> :ok
          {:error, _reason} = error -> compensate_added_state_label(context, new_label, error)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp complete_label_swap(context, new_label) do
    with {:ok, current_issue_body} <- fetch_current_issue_body(context) do
      remove_state_labels(
        context.request_fun,
        context.token,
        context.owner,
        context.repo,
        context.issue_number,
        current_issue_body,
        context.prefix,
        exclude: [new_label]
      )
    end
  end

  defp compensate_added_state_label(context, new_label, original_error) do
    case remove_label(context.issue_number, new_label, request_fun: context.request_fun) do
      :ok ->
        original_error

      {:error, rollback_error} ->
        Logger.warning("Failed to compensate state label swap issue=#{context.issue_number} label=#{new_label}: #{inspect(rollback_error)}")
        original_error
    end
  end

  defp fetch_current_issue_body(context) do
    case Issues.fetch_issue_raw_conditional(
           context.issue_number,
           issue_read_opts(context) |> Keyword.put(:revalidate, true)
         ) do
      {:ok, issue_body, _outcome} -> {:ok, issue_body}
      {:error, _reason} = error -> error
    end
  end

  @spec swap_and_maybe_close_issue(map(), map(), String.t(), String.t()) :: :ok | {:error, term()}
  def swap_and_maybe_close_issue(context, issue_body, state_name, new_label) do
    with :ok <-
           swap_labels(
             context,
             issue_body,
             state_name,
             new_label
           ) do
      maybe_close_issue(context.request_fun, context.token, context.issue_url, state_name)
    end
  end

  @spec add_state_label(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def add_state_label(context, state_name, new_label) do
    if StatePolicy.active_target_state?(state_name) do
      add_active_issue_label(context, new_label)
    else
      add_issue_label(
        context.request_fun,
        context.token,
        context.owner,
        context.repo,
        context.issue_number,
        new_label
      )
    end
  end

  @spec add_active_issue_label(map(), String.t()) :: :ok | {:error, term()}
  def add_active_issue_label(context, new_label) do
    case Issues.fetch_issue_raw_conditional(context.issue_number, issue_read_opts(context)) do
      {:ok, issue_body, _outcome} ->
        if closed_issue?(issue_body) do
          # Same honesty rule as `apply_issue_state_update/4`: an active label
          # cannot be written to a closed issue, so report the unfulfilled
          # write instead of a false `:ok` after stripping stale active labels
          # (#2420).
          handle_closed_active_target(context, issue_body)
        else
          add_issue_label(
            context.request_fun,
            context.token,
            context.owner,
            context.repo,
            context.issue_number,
            new_label
          )
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp issue_read_opts(%{request_fun: request_fun, token: token}),
    do: [token: token, request_fun: request_fun]

  # Expected-state guards need an authoritative body: an ETag can validate a
  # stale stored snapshot when equal updated_at values allowed a racing deposit.
  defp guarded_issue_read_opts(context), do: Keyword.put(issue_read_opts(context), :unconditional, true)

  defp retry_local_holds(request_fun, opts) do
    fn request ->
      request_fun
      |> retry_request(request, opts)
      |> restore_local_hold_error()
    end
  end

  defp retry_request(request_fun, request, opts) do
    LocalHold.run(fn -> classify_raw_local_hold(request_fun.(request)) end, LocalHold.caller_opts(opts))
  end

  defp classify_raw_local_hold({:error, {:aiur, :locally_held, _hold}} = error),
    do: {:error, Errors.classify_error(error)}

  defp classify_raw_local_hold({:error, :github_budget_broker_timeout}),
    do: {:error, Errors.classify_error({:error, :github_budget_broker_timeout})}

  defp classify_raw_local_hold(response), do: response

  defp restore_local_hold_error({:error, {:github, :local_hold, %{reason: {:aiur, :locally_held, _hold} = reason}}}),
    do: {:error, reason}

  defp restore_local_hold_error({:error, {:github, :local_hold, %{reason: :github_budget_broker_timeout}}}),
    do: {:error, :github_budget_broker_timeout}

  defp restore_local_hold_error(response), do: response

  @spec remove_state_labels(function(), String.t(), String.t(), String.t(), String.t(), map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def remove_state_labels(request_fun, token, owner, repo, issue_number, issue_body, prefix, opts \\ []) do
    excluded = Keyword.get(opts, :exclude, []) |> Enum.map(&normalize_label_name/1)

    issue_body
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name", ""))
    |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
    |> Enum.reject(fn label ->
      preserved_prefixed_label?(label, prefix) or normalize_label_name(label) in excluded
    end)
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case delete_issue_label(request_fun, token, owner, repo, issue_number, label) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec remove_active_state_labels(function(), String.t(), String.t(), String.t(), String.t(), map(), String.t()) ::
          :ok | {:error, term()}
  def remove_active_state_labels(
        request_fun,
        token,
        owner,
        repo,
        issue_number,
        issue_body,
        prefix
      ) do
    issue_body
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name", ""))
    |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
    |> Enum.reject(&(StatePolicy.terminal_state_label?(&1, prefix) or preserved_prefixed_label?(&1, prefix)))
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case delete_issue_label(request_fun, token, owner, repo, issue_number, label) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec delete_issue_label(function(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def delete_issue_label(request_fun, token, owner, repo, issue_number, label) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"

    case request_fun.(%{method: :delete, url: url, token: token}) do
      {:ok, %{status: status, body: labels}} when status in [200, 204] ->
        WriteThrough.issue_labels(issue_number, labels)
        :ok

      {:ok, %{status: status}} when status in [200, 204, 404] ->
        :ok

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec add_issue_label(function(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def add_issue_label(request_fun, token, owner, repo, issue_number, label) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels"

    case request_fun.(%{method: :post, url: url, token: token, body: %{"labels" => [label]}}) do
      {:ok, %{status: status, body: labels}} when status in [200, 201] ->
        WriteThrough.issue_labels(issue_number, labels)
        :ok

      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec maybe_close_issue(function(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def maybe_close_issue(request_fun, token, issue_url, state_name) do
    if StatePolicy.normalize_state(state_name) in ["done", "cancelled", "canceled"] do
      case request_fun.(%{
             method: :patch,
             url: issue_url,
             token: token,
             body: %{"state" => "closed"}
           }) do
        # A `PATCH /issues/:number` answers with the whole issue at its new
        # `updated_at`, so closing a ticket deposits the closed issue and marks
        # that version handled rather than leaving a sweep to rediscover it.
        {:ok, %{status: status, body: issue}} when status in [200, 201] ->
          WriteThrough.issue(issue)
          :ok

        {:ok, %{status: status}} when status in [200, 201] ->
          :ok

        {:ok, %{status: _status} = response} ->
          {:error, Errors.github_status_error(response)}

        {:error, reason} ->
          {:error, Errors.classify_error({:error, reason})}
      end
    else
      :ok
    end
  end

  @spec closed_issue?(map()) :: boolean()
  def closed_issue?(%{"state" => "closed"}), do: true
  def closed_issue?(_issue_body), do: false
  @spec preserved_prefixed_label?(term(), term()) :: boolean()
  def preserved_prefixed_label?(label, prefix) when is_binary(label) and is_binary(prefix) do
    prefix_colon = normalize_label_name("#{prefix}:")
    normalized = normalize_label_name(label)

    String.starts_with?(normalized, prefix_colon) and
      normalized
      |> String.replace_prefix(prefix_colon, "")
      |> preserved_prefixed_label_suffix?()
  end

  def preserved_prefixed_label?(_label, _prefix), do: false
  @spec preserved_prefixed_label_suffix?(term()) :: boolean()
  def preserved_prefixed_label_suffix?(suffix), do: Labels.marker_suffix?(suffix)
  @spec normalize_label_name(term()) :: String.t()
  def normalize_label_name(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  def normalize_label_name(_label), do: ""
end
