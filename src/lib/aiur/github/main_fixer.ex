defmodule Aiur.GitHub.MainFixer do
  @moduledoc false
  alias Aiur.GitHub.{Access, Config, Labels, WriteThrough}
  alias Aiur.{Issue, MergePolicy}

  @marker ~r/<!-- aiur:main-watch signature=([a-f0-9]{64}) sha=([a-f0-9]{40}) -->/

  @spec marker(term()) :: {String.t(), String.t()} | nil
  def marker(body) when is_binary(body) do
    case Regex.run(@marker, body) do
      [_, signature, sha] -> {signature, sha}
      _ -> nil
    end
  end

  def marker(_), do: nil

  @spec authorized?(Issue.t(), keyword()) :: boolean()
  def authorized?(issue, opts) do
    app = Keyword.get_lazy(opts, :app_account, &Config.app_account/0)
    watch = Keyword.get_lazy(opts, :main_watch, fn -> MergePolicy.current().main_watch end)

    app_mode?(opts) and String.downcase(issue.creator_login || "") == String.downcase(app || "") and
      MergePolicy.fixer_ticket?(issue, watch) and not is_nil(marker(issue.description))
  end

  @spec app_mode?(keyword()) :: boolean()
  def app_mode?(opts \\ []) do
    app = Keyword.get_lazy(opts, :app_account, &Config.app_account/0)
    bot = Keyword.get_lazy(opts, :bot_account, &Config.bot_account/0)
    source = Keyword.get_lazy(opts, :token_source, &Config.token_source/0)
    source == :github_app and is_binary(app) and app != "" and is_binary(bot) and bot != "" and String.downcase(app) != String.downcase(bot || "")
  end

  @spec create(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(body, opts) do
    with {:ok, {owner, repo}} <- Access.parse_repo(), {:ok, token} <- Access.require_token(opts), :ok <- Labels.ensure(owner, repo, token, body["labels"], opts) do
      case Keyword.get(opts, :request_fun, &Access.default_request_fun/1).(%{
             method: :post,
             url: "#{Access.base_url()}/repos/#{owner}/#{repo}/issues",
             token: token,
             body: body,
             caller: "main_fixer_create"
           }) do
        {:ok, %{status: 201, body: %{"number" => _} = issue}} ->
          WriteThrough.issue(issue)
          {:ok, issue}

        {:ok, response} ->
          {:error, Access.github_status_error(response)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
