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

  @base_url "https://api.github.com"
  @api_version "2022-11-28"

  # Agent lifecycle state suffixes the orchestrator manages. Test-reset cleanup
  # consumes `state_labels/1` directly so this remains the single source.
  @state_suffixes ~w(todo in-progress ci-wait human-review rework merging done error cancelled canceled)

  # Marker labels. NOT lifecycle states — the orchestrator never treats these as
  # dispatch states. Kept out of `@state_suffixes` so they never enter the state
  # machine, but created by `label_set/2` so `aiur init` seeds them and the
  # Executor can apply them.
  @watch_suffix "watch"
  @paused_suffix "paused"
  @rate_limit_fallback_suffix "rate-limit-fallback"
  @marker_suffixes [@watch_suffix, @paused_suffix, @rate_limit_fallback_suffix]

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
    state_labels(prefix) ++
      required_rate_limit_fallback_labels(prefix) ++
      (marker_labels(prefix) -- rate_limit_fallback_marker_labels(prefix)) ++
      model_labels(backends) ++ alias_labels(backends) ++ effort_labels() ++ complexity_labels()
  end

  @spec state_labels(String.t()) :: [String.t()]
  def state_labels(prefix), do: Enum.map(@state_suffixes, &"#{prefix}:#{&1}")

  @doc "The opt-in PR-watch marker label, given the prefix (e.g. `agent:watch`)."
  @spec watch_labels(String.t()) :: [String.t()]
  def watch_labels(prefix), do: ["#{prefix}:#{@watch_suffix}"]

  @doc "The per-issue pause override marker label, given the prefix (e.g. `agent:paused`)."
  @spec paused_labels(String.t()) :: [String.t()]
  def paused_labels(prefix), do: ["#{prefix}:#{@paused_suffix}"]

  @doc "The marker that records ownership of an automatic usage-limit fallback."
  @spec rate_limit_fallback_marker_labels(String.t()) :: [String.t()]
  def rate_limit_fallback_marker_labels(prefix), do: ["#{prefix}:#{@rate_limit_fallback_suffix}"]

  @spec marker_labels(String.t()) :: [String.t()]
  def marker_labels(prefix), do: Enum.map(@marker_suffixes, &"#{prefix}:#{&1}")

  @doc "Labels required for the configured rate-limit fallback pair."
  @spec required_rate_limit_fallback_labels(String.t()) :: [String.t()]
  def required_rate_limit_fallback_labels(prefix),
    do: required_rate_limit_fallback_labels(prefix, CodingAgent.default_backend(), CodingAgent.default_rate_limit_fallback())

  @spec required_rate_limit_fallback_labels(String.t(), String.t(), String.t() | nil) :: [String.t()]
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
    do: String.downcase(String.trim(suffix)) in @marker_suffixes

  def marker_suffix?(_suffix), do: false

  @spec model_labels([String.t()]) :: [String.t()]
  def model_labels(backends), do: CodingAgent.override_labels(backends)

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
  def describe("complexity:" <> n), do: "story-point complexity #{n}"
  def describe("model:remote"), do: "Supports claude remote-control"

  def describe("model:" <> spec = label) do
    if label in effort_labels(),
      do: "run this issue at #{spec} reasoning effort",
      else: "route this issue to #{spec}"
  end

  def describe(label) do
    case String.split(label, ":", parts: 2) do
      [_prefix, suffix] -> state_description(suffix)
      _ -> ""
    end
  end

  defp state_description("watch"), do: "aiur watches this PR for comments"
  defp state_description("paused"), do: "suppress aiur work while preserving state"
  defp state_description("rate-limit-fallback"), do: "tracks automatic usage-limit fallback"
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

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status, label}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp already_exists?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, fn error -> is_map(error) and error["code"] == "already_exists" end)
  end

  defp already_exists?(_body), do: false

  defp default_request_fun(%{method: :post, url: url, token: token, body: body}) do
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", @api_version}
    ]

    Req.post(url, headers: headers, json: body, connect_options: [timeout: 30_000])
  end
end
