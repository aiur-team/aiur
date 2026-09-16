defmodule Aiur.GitHub.StateLabelPreflight do
  @moduledoc """
  Verifies that the configured repository carries every `<prefix>:<state>`
  label the orchestrator dispatches on.

  A repo with no state labels is silently undispatchable: no ticket can be
  labelled into the workflow, so the daemon polls forever and reads as "no work
  left" (#2639). The dispatcher runs this once at its first dispatch cycle and
  raises a needs-attention alert naming the missing labels, in the same family
  as the tracker authentication preflight. The check is advisory: it never
  holds dispatch, because missing labels mean there is nothing to hold.

  Network calls go through an injected `request_fun` so the check is testable
  with no real HTTP.
  """

  alias Aiur.GitHub.Config
  alias Aiur.GitHub.Labels
  alias Aiur.GitHub.Transport

  @per_page 100

  @type result :: %{repo: String.t(), missing: [String.t()], present: [String.t()]}

  @doc """
  The check the dispatcher runs. Overridable through the
  `:state_label_preflight_fun` application env so orchestrator tests never
  touch GitHub.
  """
  @spec check_fun() :: (-> {:ok, result()} | {:error, term()})
  def check_fun do
    Application.get_env(:aiur, :state_label_preflight_fun, &check/0)
  end

  @doc """
  Lists the repository's labels and reports which required state labels are
  absent. `{:error, reason}` means the answer is unknown (no repo, no token,
  or the list call failed), never that labels are missing.
  """
  @spec check(keyword()) :: {:ok, result()} | {:error, term()}
  def check(opts \\ []) do
    with {:ok, {owner, name}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      required = Labels.state_labels(Config.label_prefix())

      case list_label_names(request_fun, owner, name, token, 1, []) do
        {:ok, names} ->
          {:ok, %{repo: "#{owner}/#{name}", missing: required -- names, present: required -- (required -- names)}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Operator-facing sentence naming the missing labels and how to create them."
  @spec format_missing(result()) :: String.t()
  def format_missing(%{repo: repo, missing: missing}) do
    "Repository #{repo} is missing the workflow state labels #{Enum.join(missing, ", ")}. " <>
      "No ticket can be labelled into the workflow until they exist, so dispatch has nothing to pick up. " <>
      "Run `aiur init` with GITHUB_TOKEN set to create them, or create them by hand: " <>
      Enum.map_join(missing, "; ", &gh_label_create(&1, repo))
  end

  defp gh_label_create(label, repo) do
    "gh label create #{shell_arg(label)} --repo #{repo} --description #{shell_arg(Labels.describe(label))} --force"
  end

  defp shell_arg(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"

  defp list_label_names(request_fun, owner, name, token, page, acc) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{name}/labels?per_page=#{@per_page}&page=#{page}"

    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_list(body) ->
        names = acc ++ Enum.map(body, & &1["name"])

        if length(body) == @per_page,
          do: list_label_names(request_fun, owner, name, token, page + 1, names),
          else: {:ok, names}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end
end
