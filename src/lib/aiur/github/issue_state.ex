defmodule Aiur.GitHub.IssueState do
  @moduledoc """
  Label-encoded issue state writes for GitHub issues.

  This module owns issue state transitions implemented as GitHub label swaps,
  terminal-state closing, and raw per-issue label add/remove primitives. It
  preserves the closed-issue recheck before adding active labels so stale state
  removal cannot reopen or relabel a closed issue.
  """

  alias Aiur.GitHub.Config
  alias Aiur.GitHub.{Errors, HumanReviewGate, Issues, Labels, StatePolicy, Transport, WriteThrough}

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_number, state_name, opts \\ [])
      when is_binary(issue_number) and is_binary(state_name) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      prefix = Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
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
        # The target is an active state but the issue reads as closed, so no
        # active state label can be written. Removing the stale active labels
        # and returning `:ok` reported a successful transition for a write that
        # did not happen — a stale cached body would strand an open ticket
        # while recording success (#2420). Report it honestly instead.
        case remove_active_state_labels(
               context.request_fun,
               context.token,
               context.owner,
               context.repo,
               context.issue_number,
               current_issue_body,
               context.prefix
             ) do
          :ok -> {:error, {:no_state_label_written, current_issue_body}}
          {:error, _reason} = error -> error
        end
      else
        swap_and_maybe_close_issue(context, current_issue_body, state_name, new_label)
      end
    end
  end

  defp revalidate_expected_state(%{opts: opts} = context, issue_body) do
    if Keyword.has_key?(opts, :expected_state) do
      # The point of this second read is to be *sure* the state has not moved
      # since the first, so it must always contact GitHub — `revalidate: true`
      # skips the served-from-store path and sends the held ETag, which costs a
      # free `304` when nothing changed.
      case Issues.fetch_issue_raw_conditional(
             context.issue_number,
             issue_read_opts(context) |> Keyword.put(:revalidate, true)
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
    case Keyword.fetch(opts, :expected_state) do
      :error ->
        :ok

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
  def swap_labels(context, issue_body, state_name, new_label) do
    # Add the new state label BEFORE removing the old ones (#2420). Remove-then-
    # add left the ticket carrying zero `agent:*` state labels between the two
    # calls, and any POST failure stranded it there permanently — invisible to
    # dispatch and unrepaired by any reconciler. Add-first means a failure
    # between the calls leaves *two* state labels (recoverable and detectable)
    # instead of zero, and the removal set excludes the just-added label.
    with :ok <- add_state_label(context, state_name, new_label) do
      remove_state_labels(
        context.request_fun,
        context.token,
        context.owner,
        context.repo,
        context.issue_number,
        issue_body,
        context.prefix,
        exclude: [new_label]
      )
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
          case remove_active_state_labels(
                 context.request_fun,
                 context.token,
                 context.owner,
                 context.repo,
                 context.issue_number,
                 issue_body,
                 context.prefix
               ) do
            :ok -> {:error, {:no_state_label_written, issue_body}}
            {:error, _reason} = error -> error
          end
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

  # Options for the shared issue conditional reader. The token is passed
  # explicitly so `Transport.require_token/1` never falls through to its
  # `:request_fun` test seam in production (the caller's real token wins either
  # way), and `request_fun` is forwarded only when the caller supplied one —
  # a caller with no override must not be handed the synthetic test token.
  defp issue_read_opts(%{opts: opts, request_fun: request_fun, token: token}) do
    if Keyword.has_key?(opts, :request_fun) do
      [token: token, request_fun: request_fun]
    else
      [token: token]
    end
  end

  @spec remove_state_labels(function(), String.t(), String.t(), String.t(), String.t(), map(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def remove_state_labels(request_fun, token, owner, repo, issue_number, issue_body, prefix, opts \\ []) do
    # Labels named in `exclude` are left on the issue. `swap_labels/4` adds the
    # new state label before calling this and passes it through so the swap
    # cannot delete the label it just added (#2420).
    excluded = Keyword.get(opts, :exclude, []) |> Enum.map(&normalize_label_name/1)

    issue_body
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name", ""))
    |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
    |> Enum.reject(&preserved_prefixed_label?(&1, prefix))
    |> Enum.reject(&(normalize_label_name(&1) in excluded))
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
