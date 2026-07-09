defmodule Aiur.GitHub.Client do
  @moduledoc """
  GitHub REST API client for issue tracking via labels.
  """

  alias Aiur.GitHub

  alias Aiur.GitHub.{
    AuthPreflight,
    BotIdentity,
    Comments,
    DependenciesApi,
    Errors,
    Issues,
    PullRequests,
    RepoEvents,
    ReviewThreads,
    StatePolicy,
    Teams,
    Transport
  }

  @preserved_prefixed_label_suffixes ~w(paused watch)

  @spec preflight_auth(keyword()) :: :ok | {:error, term()}
  def preflight_auth(opts \\ []), do: AuthPreflight.preflight_auth(opts)

  @spec format_auth_preflight_error(term()) :: String.t()
  def format_auth_preflight_error(reason), do: AuthPreflight.format_auth_preflight_error(reason)

  @type classification :: Errors.classification()

  @doc """
  Classifies a GitHub transport failure or HTTP response into the structured
  error taxonomy `{:github, classification, detail}`.

  Accepts either:

    * `{:error, reason}` — a transport failure, where `reason` is a
      `Req.TransportError`/`Mint.TransportError` (or bare reason). DNS
      (`:nxdomain`) → `:dns`; connectivity (`:timeout`/`:closed`/`:econnrefused`
      …) → `:timeout`; TLS alerts → `:tls`; anything else → `:transport`.
    * an HTTP response map `%{status: ...}` — 401 → `:auth`; a 403 carrying a
      rate-limit signal → `:rate_limited`; any other status → `:http`.

  `detail` is a map (`%{reason: ...}` for transport, `%{status: ...}` for HTTP,
  plus `:retry_after`/`:poll_interval` for rate-limit) so callers can both
  pattern-match the classification and recover the specifics.
  """
  @spec classify_error({:error, term()} | map()) :: {:github, classification(), map()}
  def classify_error(error), do: Errors.classify_error(error)

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []), do: Issues.fetch_candidate_issues(opts)

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []), do: Issues.fetch_issues_by_states(state_names, opts)

  @spec fetch_issue_states_by_ids([String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []), do: Issues.fetch_issue_states_by_ids(issue_ids, opts)

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_number, body, opts \\ []), do: Comments.create_comment(issue_number, body, opts)

  @spec fetch_repo_events(keyword()) ::
          {:ok,
           {:events, [map()], String.t() | nil, pos_integer()}
           | {:not_modified, String.t() | nil, pos_integer()}}
          | {:error, term()}
  def fetch_repo_events(opts \\ []), do: RepoEvents.fetch_repo_events(opts)

  @spec fetch_blocked_by(integer() | String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_blocked_by(issue_number, opts \\ []), do: DependenciesApi.fetch_blocked_by(issue_number, opts)

  @spec fetch_blocking(integer() | String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_blocking(issue_number, opts \\ []), do: DependenciesApi.fetch_blocking(issue_number, opts)

  @spec add_dependency(integer() | String.t(), integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def add_dependency(blocked_issue_number, blocker_issue_id, opts \\ []),
    do: DependenciesApi.add_dependency(blocked_issue_number, blocker_issue_id, opts)

  @spec remove_dependency(integer() | String.t(), integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def remove_dependency(blocked_issue_number, blocker_issue_id, opts \\ []),
    do: DependenciesApi.remove_dependency(blocked_issue_number, blocker_issue_id, opts)

  @spec fetch_issue_raw(integer() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_issue_raw(issue_number, opts \\ []), do: Issues.fetch_issue_raw(issue_number, opts)

  @spec fetch_team_members(String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_team_members(org, team_slug, opts \\ []), do: Teams.fetch_team_members(org, team_slug, opts)

  @spec fetch_pull_request_changed_paths(String.t() | integer(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_pull_request_changed_paths(pr_number, opts \\ []),
    do: PullRequests.fetch_pull_request_changed_paths(pr_number, opts)

  @spec fetch_pull_request_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_pull_request_review_comments(pr_number, opts \\ []),
    do: PullRequests.fetch_pull_request_review_comments(pr_number, opts)

  @spec fetch_open_pull_request_for_branch(String.t() | integer(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch(issue_number, opts \\ []),
    do: PullRequests.fetch_open_pull_request_for_branch(issue_number, opts)

  @spec fetch_open_pull_requests_by_label(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests_by_label(label, opts \\ []),
    do: PullRequests.fetch_open_pull_requests_by_label(label, opts)

  @spec fetch_recent_repo_review_comments(keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_recent_repo_review_comments(opts \\ []), do: Comments.fetch_recent_repo_review_comments(opts)

  @spec fetch_recent_repo_issue_comments(keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_recent_repo_issue_comments(opts \\ []), do: Comments.fetch_recent_repo_issue_comments(opts)

  @spec fetch_issue_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_number, opts \\ []), do: Comments.fetch_issue_comments(issue_number, opts)

  @spec fetch_pull_request_head_ref(String.t() | integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_pull_request_head_ref(pr_number, opts \\ []),
    do: PullRequests.fetch_pull_request_head_ref(pr_number, opts)

  @spec fetch_open_pull_request(String.t() | integer(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request(pr_number, opts \\ []),
    do: PullRequests.fetch_open_pull_request(pr_number, opts)

  @spec fetch_classified_pr_review_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_review_comments(pr_number, opts \\ []),
    do: PullRequests.fetch_classified_pr_review_comments(pr_number, opts)

  @spec fetch_unaddressed_pr_review_thread_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_unaddressed_pr_review_thread_comments(pr_number, opts \\ []),
    do: ReviewThreads.fetch_unaddressed_pr_review_thread_comments(pr_number, opts)

  @spec reply_to_review_thread(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reply_to_review_thread(review_thread_id, body, opts \\ []),
    do: ReviewThreads.Reply.reply_to_review_thread(review_thread_id, body, opts)

  @spec resolve_review_thread(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_review_thread(review_thread_id, opts \\ []),
    do: ReviewThreads.Resolution.resolve_review_thread(review_thread_id, opts)

  @spec verify_human_review_ready(String.t() | integer(), keyword()) :: :ok | {:error, term()}
  def verify_human_review_ready(issue_number, opts \\ []) do
    with {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      context = %{
        issue_number: to_string(issue_number),
        request_fun: request_fun,
        token: token,
        opts: opts
      }

      verify_issue_review_threads_clear(context)
    end
  end

  @spec fetch_classified_issue_comments(String.t() | integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_classified_issue_comments(issue_number, opts \\ []),
    do: Comments.fetch_classified_issue_comments(issue_number, opts)

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_number, state_name, opts \\ [])
      when is_binary(issue_number) and is_binary(state_name) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token() do
      prefix = GitHub.Config.label_prefix()
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
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: _status} = response} -> {:error, Errors.github_status_error(response)}
        {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
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
        # 404 = label already absent; treat as success so the toggle is idempotent.
        {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
        {:ok, %{status: _status} = response} -> {:error, Errors.github_status_error(response)}
        {:error, reason} -> {:error, Errors.classify_error({:error, reason})}
      end
    end
  end

  # -- Private helpers --------------------------------------------------------

  defp do_update_issue_state(update_context, state_name) do
    new_label = StatePolicy.state_label(update_context.prefix, state_name)

    case update_context.request_fun.(%{
           method: :get,
           url: update_context.issue_url,
           token: update_context.token
         }) do
      {:ok, %{status: 200, body: issue_body}} ->
        apply_issue_state_update(update_context, issue_body, state_name, new_label)

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp apply_issue_state_update(context, issue_body, state_name, new_label) do
    with :ok <- verify_human_review_review_threads_clear(context, state_name) do
      if closed_issue?(issue_body) and StatePolicy.active_target_state?(state_name) do
        remove_active_state_labels(
          context.request_fun,
          context.token,
          context.owner,
          context.repo,
          context.issue_number,
          issue_body,
          context.prefix
        )
      else
        swap_and_maybe_close_issue(context, issue_body, state_name, new_label)
      end
    end
  end

  defp verify_human_review_review_threads_clear(context, state_name) do
    if StatePolicy.human_review_target_state?(state_name) do
      verify_issue_review_threads_clear(context)
    else
      :ok
    end
  end

  defp verify_issue_review_threads_clear(context) do
    case fetch_open_pull_request_for_branch(context.issue_number,
           request_fun: context.request_fun,
           token: context.token
         ) do
      {:ok, %{"number" => pr_number}} when is_integer(pr_number) ->
        with {:ok, agent_login} <-
               BotIdentity.bot_account(context.opts, context.request_fun, context.token) do
          verify_pr_review_threads_clear(context, pr_number, agent_login)
        end

      {:ok, nil} ->
        :ok

      {:ok, _pr} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_pr_review_threads_clear(context, pr_number, agent_login) do
    case fetch_unaddressed_pr_review_thread_comments(pr_number,
           request_fun: context.request_fun,
           token: context.token,
           agent_logins: [agent_login | Keyword.get(context.opts, :agent_logins, [])]
         ) do
      {:ok, []} ->
        :ok

      {:ok, comments} ->
        {:error,
         {:unverified_review_threads,
          %{
            issue_number: context.issue_number,
            pr_number: pr_number,
            review_thread_ids: Enum.map(comments, &Map.get(&1, "review_thread_id")) |> Enum.reject(&is_nil/1),
            comment_ids: Enum.map(comments, &Map.get(&1, "id")) |> Enum.reject(&is_nil/1),
            count: length(comments)
          }}}

      {:error, _reason} = error ->
        error
    end
  end

  defp remove_active_state_labels(
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

  defp swap_and_maybe_close_issue(context, issue_body, state_name, new_label) do
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

  defp swap_labels(context, issue_body, state_name, new_label) do
    with :ok <-
           remove_state_labels(
             context.request_fun,
             context.token,
             context.owner,
             context.repo,
             context.issue_number,
             issue_body,
             context.prefix
           ) do
      add_state_label(context, state_name, new_label)
    end
  end

  defp add_state_label(context, state_name, new_label) do
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

  defp add_active_issue_label(context, new_label) do
    case context.request_fun.(%{method: :get, url: context.issue_url, token: context.token}) do
      {:ok, %{status: 200, body: issue_body}} ->
        if closed_issue?(issue_body) do
          remove_active_state_labels(
            context.request_fun,
            context.token,
            context.owner,
            context.repo,
            context.issue_number,
            issue_body,
            context.prefix
          )
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

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp remove_state_labels(request_fun, token, owner, repo, issue_number, issue_body, prefix) do
    issue_body
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name", ""))
    |> Enum.filter(&String.starts_with?(&1, "#{prefix}:"))
    |> Enum.reject(&preserved_prefixed_label?(&1, prefix))
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case delete_issue_label(request_fun, token, owner, repo, issue_number, label) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delete_issue_label(request_fun, token, owner, repo, issue_number, label) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{URI.encode(label)}"

    case request_fun.(%{method: :delete, url: url, token: token}) do
      {:ok, %{status: status}} when status in [200, 204, 404] ->
        :ok

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp add_issue_label(request_fun, token, owner, repo, issue_number, label) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}/labels"

    case request_fun.(%{method: :post, url: url, token: token, body: %{"labels" => [label]}}) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp maybe_close_issue(request_fun, token, issue_url, state_name) do
    if StatePolicy.normalize_state(state_name) in ["done", "cancelled", "canceled"] do
      case request_fun.(%{
             method: :patch,
             url: issue_url,
             token: token,
             body: %{"state" => "closed"}
           }) do
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

  defp closed_issue?(%{"state" => "closed"}), do: true
  defp closed_issue?(_issue_body), do: false

  defp preserved_prefixed_label?(label, prefix) when is_binary(label) and is_binary(prefix) do
    prefix_colon = normalize_label_name("#{prefix}:")
    normalized = normalize_label_name(label)

    String.starts_with?(normalized, prefix_colon) and
      normalized
      |> String.replace_prefix(prefix_colon, "")
      |> preserved_prefixed_label_suffix?()
  end

  defp preserved_prefixed_label?(_label, _prefix), do: false

  defp preserved_prefixed_label_suffix?(suffix) when is_binary(suffix) do
    suffix in @preserved_prefixed_label_suffixes
  end

  defp normalize_label_name(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label_name(_label), do: ""
end
