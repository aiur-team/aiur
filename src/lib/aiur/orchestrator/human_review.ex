defmodule Aiur.Orchestrator.HumanReview do
  @moduledoc """
  Owns orchestrator HumanReview behavior.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.GitHub.Tracker, as: GitHubTracker
  alias Aiur.{Issue, Tracker}
  alias Aiur.Orchestrator.{AgentTeardown, DispatchPolicy, Reconciler, State}
  @transient_github_graphql_error_types ~w(
    INTERNAL
    INTERNAL_SERVER_ERROR
    RATE_LIMITED
    SERVER_ERROR
    SERVICE_UNAVAILABLE
    TIMEOUT
  )

  @doc false
  @spec human_review_state?(binary() | term()) :: boolean()
  def human_review_state?(state_name) when is_binary(state_name) do
    DispatchPolicy.normalize_issue_state(state_name) == "human-review"
  end

  def human_review_state?(_), do: false

  @doc false
  @spec maybe_deactivate_human_review_issue(State.t(), Issue.t()) :: State.t()
  def maybe_deactivate_human_review_issue(%State{} = state, %Issue{} = issue) do
    case verify_human_review_ready(issue) do
      :ok ->
        AgentTeardown.deactivate_running_issue(state, issue.id)

      {:error, reason} ->
        if transient_human_review_verification_error?(reason) do
          defer_human_review_transition(state, issue, reason)
        else
          reject_human_review_transition(state, issue, reason)
        end
    end
  end

  defp verify_human_review_ready(%Issue{id: issue_id}) when is_binary(issue_id) do
    case Application.get_env(:aiur, :human_review_ready_verifier) do
      verifier when is_function(verifier, 1) ->
        verifier.(issue_id)

      _ ->
        verify_human_review_ready_with_tracker(issue_id)
    end
  end

  defp verify_human_review_ready(_issue), do: :ok

  defp transient_human_review_verification_error?({:github, kind, _detail})
       when kind in [:dns, :timeout, :tls, :transport, :rate_limited],
       do: true

  defp transient_human_review_verification_error?({:github_api_status, status})
       when status in [408, 429] or status in 500..599,
       do: true

  defp transient_human_review_verification_error?({:github_graphql_errors, errors})
       when is_list(errors),
       do: Enum.any?(errors, &transient_github_graphql_error?/1)

  defp transient_human_review_verification_error?(_reason), do: false

  defp transient_github_graphql_error?(error) when is_map(error) do
    error
    |> github_graphql_error_values()
    |> Enum.any?(&transient_github_graphql_error_value?/1)
  end

  defp transient_github_graphql_error?(_error), do: false

  defp github_graphql_error_values(error) do
    [
      Map.get(error, "type"),
      Map.get(error, :type),
      Map.get(error, "code"),
      Map.get(error, :code),
      get_in(error, ["extensions", "code"]),
      get_in(error, [:extensions, :code])
    ]
  end

  defp transient_github_graphql_error_value?(value) when is_atom(value),
    do: value |> Atom.to_string() |> transient_github_graphql_error_value?()

  defp transient_github_graphql_error_value?(value) when is_binary(value),
    do: String.upcase(value) in @transient_github_graphql_error_types

  defp transient_github_graphql_error_value?(_value), do: false

  defp defer_human_review_transition(%State{} = state, %Issue{} = issue, reason) do
    Logger.warning("human-review transition verification deferred: #{State.issue_context(issue)} reason=#{inspect(reason)}")

    state
  end

  defp verify_human_review_ready_with_tracker(issue_id) do
    if Tracker.adapter() == GitHubTracker do
      client = github_client_module()

      if function_exported?(client, :verify_human_review_ready, 1) do
        client.verify_human_review_ready(issue_id)
      else
        :ok
      end
    else
      :ok
    end
  end

  defp reject_human_review_transition(%State{} = state, %Issue{} = issue, reason) do
    issue_key = issue.id || issue.identifier

    Logger.warning("human-review transition rejected; reverting to rework: #{State.issue_context(issue)} reason=#{inspect(reason)}")

    case Tracker.update_issue_state(to_string(issue_key), "rework") do
      :ok ->
        Reconciler.maybe_reactivate_or_refresh(state, %{issue | state: "rework"})

      {:error, update_reason} ->
        Logger.warning("human-review rework revert failed: #{State.issue_context(issue)} reason=#{inspect(update_reason)}")

        state
    end
  end

  defp github_client_module do
    Application.get_env(:aiur, :github_client_module, GitHubClient)
  end
end
