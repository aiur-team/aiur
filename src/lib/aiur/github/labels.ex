defmodule Aiur.GitHub.Labels do
  @moduledoc """
  Derives and idempotently creates the GitHub labels aiur depends on.

  Three families:

    * **state** — `<prefix>:<state>` for every agent lifecycle state the
      orchestrator sets and reads.
    * **model** — `Aiur.CodingAgent.override_labels/1` for the backends the
      Executor chose, so an issue can be pinned to a specific agent/model.
    * **complexity** — `complexity:1`..`complexity:5`, routed to an agent via
      `agent.routing`.

  Network calls go through an injected `request_fun` so the wizard is testable
  with no real HTTP. Headers mirror `Aiur.GitHub.Client`.
  """

  alias Aiur.CodingAgent
  alias Aiur.GitHub.Errors
  alias Aiur.GitHub.Transport

  @base_url "https://api.github.com"

  # Agent lifecycle state suffixes the orchestrator manages. Test-reset cleanup
  # consumes `state_labels/1` directly so this remains the single source.
  @state_suffixes ~w(todo in-progress ci-wait human-review rework merging done error cancelled canceled)
  @reason_modifier_suffixes ~w(merge-queued ci-red body-fix paused-usage-limit paused-decision paused-agent retrying blocked handed-off)
  @runtime_reason_modifiers %{
    usage_limit_exhausted: "paused-usage-limit",
    provider_limited: "paused-usage-limit",
    input_required: "paused-decision",
    waiting_for_human: "paused-decision",
    agent_pause_request: "paused-agent",
    blocker_dependency: "blocked",
    waiting_for_dependency: "blocked",
    backing_off: "retrying",
    merge_queue: "merge-queued",
    ci_red: "ci-red",
    body_fix: "body-fix",
    handed_off: "handed-off",
    workspace_ownership_waiting: "handed-off",
    workspace_retained: "handed-off"
  }

  # Static marker labels. NOT lifecycle states — the orchestrator never treats
  # these as dispatch states. Owner-valued Executor labels are dynamic and are
  # ensured by `aiur take` when one is written.
  @watch_suffix "watch"
  @paused_suffix "paused"
  @parked_suffix "parked"
  @executor_suffix "executor"
  @queued_suffix "queued"
  @rate_limit_fallback_suffix "rate-limit-fallback"
  @marker_suffixes [
    @watch_suffix,
    @paused_suffix,
    @parked_suffix,
    @queued_suffix,
    @rate_limit_fallback_suffix
  ]

  @type request :: %{
          method: :post,
          url: String.t(),
          token: String.t(),
          body: map()
        }
  @type response :: {:ok, %{status: integer(), body: term()}} | {:error, term()}
  @type request_fun :: (request() -> response())

  @doc "Full label set to create for a repo, given the label prefix and chosen backends."
  @spec label_set(String.t(), [String.t()]) :: [String.t()]
  def label_set(prefix, backends) do
    ["flake"] ++
      state_labels(prefix) ++
      reason_modifier_labels(prefix) ++
      required_rate_limit_fallback_labels(prefix) ++
      (marker_labels(prefix) -- rate_limit_fallback_marker_labels(prefix)) ++
      model_labels(backends) ++ alias_labels(backends) ++ effort_labels() ++ complexity_labels()
  end

  @spec state_labels(String.t()) :: [String.t()]
  def state_labels(prefix), do: Enum.map(@state_suffixes, &"#{prefix}:#{&1}")

  @doc "The complete set of workflow state suffixes accepted by the GitHub tracker."
  @spec state_suffixes() :: [String.t()]
  def state_suffixes, do: @state_suffixes

  @doc "Reason labels that may accompany one workflow state label."
  @spec reason_modifier_suffixes() :: [String.t()]
  def reason_modifier_suffixes, do: @reason_modifier_suffixes

  @spec reason_modifier_labels(String.t()) :: [String.t()]
  def reason_modifier_labels(prefix), do: Enum.map(@reason_modifier_suffixes, &"#{prefix}:#{&1}")

  @doc "Returns present state and reason labels in the canonical vocabulary order."
  @spec present_runtime_labels(term(), String.t()) :: [String.t()]
  def present_runtime_labels(labels, prefix) when is_list(labels) do
    present = MapSet.new(Enum.map(labels, &(String.downcase(to_string(&1)) |> String.trim())))

    (state_labels(prefix) ++ reason_modifier_labels(prefix) ++ Enum.map(~w(paused parked queued rate-limit-fallback), &"#{prefix}:#{&1}"))
    |> Enum.filter(&MapSet.member?(present, String.downcase(&1)))
  end

  def present_runtime_labels(_labels, _prefix), do: []

  @doc """
  The tracker's runtime labels plus the reason label for each live runtime
  cause (pause or waiting reason), in vocabulary order. Every surface renders
  this list verbatim, so a cause the tracker has not caught up with yet still
  shows its own label rather than a local word.
  """
  @spec runtime_labels(term(), [term()], String.t()) :: [String.t()]
  def runtime_labels(labels, causes, prefix) do
    inferred = causes |> Enum.map(&runtime_reason_modifier/1) |> Enum.reject(&is_nil/1) |> Enum.map(&"#{prefix}:#{&1}")
    present_runtime_labels(List.wrap(labels) ++ inferred, prefix)
  end

  @doc "`runtime_labels/3` without the workflow state label."
  @spec runtime_reason_labels(term(), [term()], String.t()) :: [String.t()]
  def runtime_reason_labels(labels, causes, prefix), do: runtime_labels(labels, causes, prefix) -- state_labels(prefix)

  @doc "Whether a bare suffix names a known orthogonal runtime reason."
  @spec reason_modifier_suffix?(term()) :: boolean()
  def reason_modifier_suffix?(suffix) when is_binary(suffix), do: String.downcase(String.trim(suffix)) in @reason_modifier_suffixes
  def reason_modifier_suffix?(_suffix), do: false

  @doc "Maps a runtime cause to its canonical reason-label suffix."
  @spec runtime_reason_modifier(term()) :: String.t() | nil
  def runtime_reason_modifier(reason), do: Map.get(@runtime_reason_modifiers, reason)

  @doc "The opt-in PR-watch marker label, given the prefix (e.g. `agent:watch`)."
  @spec watch_labels(String.t()) :: [String.t()]
  def watch_labels(prefix), do: ["#{prefix}:#{@watch_suffix}"]

  @doc "The per-issue pause override marker label, given the prefix (e.g. `agent:paused`)."
  @spec paused_labels(String.t()) :: [String.t()]
  def paused_labels(prefix), do: ["#{prefix}:#{@paused_suffix}"]

  @doc "The explicit operator-held marker label, given the prefix (e.g. `agent:parked`)."
  @spec parked_labels(String.t()) :: [String.t()]
  def parked_labels(prefix), do: ["#{prefix}:#{@parked_suffix}"]

  @doc "Prefix for the owner-valued Executor hold marker."
  @spec executor_label_prefix(String.t()) :: String.t()
  def executor_label_prefix(prefix), do: "#{prefix}:#{@executor_suffix}:"

  @doc "The build-queue marker label, given the prefix (e.g. `agent:queued`)."
  @spec queued_labels(String.t()) :: [String.t()]
  def queued_labels(prefix), do: ["#{prefix}:#{@queued_suffix}"]

  @doc "The marker that records ownership of an automatic usage-limit fallback."
  @spec rate_limit_fallback_marker_labels(String.t()) :: [String.t()]
  def rate_limit_fallback_marker_labels(prefix), do: ["#{prefix}:#{@rate_limit_fallback_suffix}"]

  @spec marker_labels(String.t()) :: [String.t()]
  def marker_labels(prefix), do: Enum.map(@marker_suffixes, &"#{prefix}:#{&1}")

  @doc "Labels required for the configured rate-limit fallback pair."
  @spec required_rate_limit_fallback_labels(String.t()) :: [String.t()]
  def required_rate_limit_fallback_labels(prefix),
    do:
      required_rate_limit_fallback_labels(
        prefix,
        CodingAgent.default_backend(),
        CodingAgent.default_rate_limit_fallback()
      )

  @spec required_rate_limit_fallback_labels(String.t(), String.t(), String.t() | nil) :: [
          String.t()
        ]
  def required_rate_limit_fallback_labels(prefix, _primary, fallback) do
    rate_limit_fallback_marker_labels(prefix) ++
      case fallback do
        backend when is_binary(backend) and backend != "" -> ["model:" <> backend]
        _ -> []
      end
  end

  @doc "Whether a prefixed-label suffix is a marker rather than a workflow state."
  @spec marker_suffix?(term()) :: boolean()
  def marker_suffix?(suffix) when is_binary(suffix),
    do: marker_name?(String.downcase(String.trim(suffix))) or reason_modifier_suffix?(suffix)

  def marker_suffix?(_suffix), do: false

  defp marker_name?("executor:" <> _owner), do: true
  defp marker_name?("executor"), do: true
  defp marker_name?(suffix), do: suffix in @marker_suffixes

  @spec model_labels([String.t()], (String.t() -> [String.t()])) :: [String.t()]
  def model_labels(backends, ids_for \\ &CodingAgent.models/1),
    do: CodingAgent.override_labels(backends, ids_for)

  # The `model:remote` flag (force remote-control on at launch) only
  # makes sense when the claude backend is chosen; it pairs with a
  # `model:claude-<variant>` tag rather than selecting a backend itself.
  @spec alias_labels([String.t()]) :: [String.t()]
  def alias_labels(backends) do
    if "claude" in backends do
      CodingAgent.alias_labels()
    else
      []
    end
  end

  # Per-ticket effort override labels (`model:xhigh`, ...). Backend-independent,
  # so they are seeded regardless of which backends the Executor chose.
  @spec effort_labels() :: [String.t()]
  def effort_labels, do: CodingAgent.override_effort_labels()

  @spec complexity_labels() :: [String.t()]
  def complexity_labels, do: Enum.map(1..5, &"complexity:#{&1}")

  @doc "A short human description for any label in `label_set/2`."
  @spec describe(String.t()) :: String.t()
  def describe("flake"), do: "known intermittent test failure"
  def describe("complexity:" <> n), do: "story-point complexity #{n}"
  def describe("model:remote"), do: "Supports claude remote-control"

  def describe("model:" <> spec = label) do
    if label in effort_labels(),
      do: "run this issue at #{spec} reasoning effort",
      else: "route this issue to #{spec}"
  end

  def describe(label) do
    case String.split(label, ":") do
      [_prefix, "executor", owner] when owner != "" ->
        "Executor-owned by #{owner}: no dispatch, no fleet slot"

      [_prefix, "executor"] ->
        "Executor-owned by unknown owner: no dispatch, no fleet slot"

      [_prefix, suffix] ->
        state_description(suffix)

      _ ->
        ""
    end
  end

  defp state_description("watch"), do: "aiur watches this PR for comments"
  defp state_description("paused"), do: "suppress aiur work while preserving state"
  defp state_description("parked"), do: "operator-held: no dispatch, no comment-driven rework"
  defp state_description("queued"), do: "in the build queue; not yet ready"
  defp state_description("rate-limit-fallback"), do: "tracks automatic usage-limit fallback"
  defp state_description("merge-queued"), do: "approved pull request is waiting in the merge queue"
  defp state_description("ci-red"), do: "required CI checks failed"
  defp state_description("body-fix"), do: "pull request body needs a documentation or evidence fix"
  defp state_description("paused-usage-limit"), do: "paused because the provider usage limit is exhausted"
  defp state_description("paused-decision"), do: "paused while waiting for an operator decision"
  defp state_description("paused-agent"), do: "paused at the agent's request"
  defp state_description("retrying"), do: "waiting for the retry back-off"
  defp state_description("blocked"), do: "blocked by an open dependency"
  defp state_description("handed-off"), do: "work handed to another Aiur instance"
  defp state_description("todo"), do: "ready to be worked"
  defp state_description("in-progress"), do: "agent is working it"
  defp state_description("ci-wait"), do: "awaiting CI before human review"
  defp state_description("human-review"), do: "awaiting human review"
  defp state_description("rework"), do: "sent back for changes"
  defp state_description("merging"), do: "merging the PR"
  defp state_description("done"), do: "completed"
  defp state_description("error"), do: "agent hit an error"
  defp state_description(state) when state in ~w(cancelled canceled), do: "work cancelled"
  defp state_description(other), do: other

  @doc """
  Create each label, stopping at the first hard failure. An existing label
  (HTTP 422 `already_exists`) counts as success so re-running is safe.
  """
  @spec ensure(String.t(), String.t(), String.t(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def ensure(owner, repo, token, labels, opts \\ []) do
    request_fun = Keyword.get(opts, :request_fun, &default_request_fun/1)
    url = "#{@base_url}/repos/#{owner}/#{repo}/labels"

    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case create_label(request_fun, url, token, label) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp create_label(request_fun, url, token, label) do
    case request_fun.(%{method: :post, url: url, token: token, body: %{"name" => label}}) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 422, body: body}} ->
        if already_exists?(body),
          do: :ok,
          else: {:error, {:github_api_status, 422, label}}

      {:ok, %{status: status} = response} ->
        label_error(response, {:github_api_status, status, label})

      {:error, reason} = error ->
        label_error(error, {:github_api_request, reason})
    end
  end

  defp label_error(response, fallback) do
    case Errors.classify_error(response) do
      {:github, kind, _} = reason when kind in [:rate_limited, :local_hold] -> {:error, reason}
      _ -> {:error, fallback}
    end
  end

  defp already_exists?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, fn error -> is_map(error) and error["code"] == "already_exists" end)
  end

  defp already_exists?(_body), do: false

  defp default_request_fun(request), do: Transport.default_request_fun(request)
end
