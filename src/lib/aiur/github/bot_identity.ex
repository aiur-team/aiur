defmodule Aiur.GitHub.BotIdentity do
  @moduledoc """
  Resolves and classifies GitHub bot identities used by review-thread flows.
  """

  alias Aiur.GitHub
  alias Aiur.GitHub.Transport

  @viewer_login_query """
  query AiurViewerLogin {
    viewer {
      login
    }
  }
  """

  @spec bot_account(keyword(), function(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def bot_account(opts, request_fun, token) do
    case opts
         |> Keyword.get_lazy(:bot_account, &GitHub.Config.bot_account/0)
         |> normalize_optional_binary() do
      bot_account when is_binary(bot_account) ->
        {:ok, bot_account}

      nil ->
        fetch_authenticated_viewer_login(request_fun, token)
    end
  end

  @spec fetch_authenticated_viewer_login(function(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_authenticated_viewer_login(request_fun, token) do
    case Transport.github_graphql(request_fun, token, @viewer_login_query, %{}) do
      {:ok, %{"data" => %{"viewer" => %{"login" => login}}}} ->
        case normalize_optional_binary(login) do
          nil -> {:error, :github_viewer_login_missing}
          viewer_login -> {:ok, viewer_login}
        end

      {:ok, _body} ->
        {:error, :github_viewer_login_missing}

      {:error, _reason} = error ->
        error
    end
  end

  @spec normalize_optional_binary(term()) :: String.t() | nil
  def normalize_optional_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_optional_binary(_value), do: nil

  @spec codeowners_classification_opts(keyword()) :: keyword()
  def codeowners_classification_opts(opts) do
    agent_logins =
      [
        Keyword.get_lazy(opts, :bot_account, &GitHub.Config.bot_account/0)
        | Keyword.get(opts, :agent_logins, [])
      ]
      |> List.flatten()
      |> Enum.flat_map(fn value ->
        case normalize_optional_binary(value) do
          nil -> []
          login -> [login]
        end
      end)
      |> Enum.uniq()

    Keyword.put(opts, :agent_logins, agent_logins)
  end

  @spec agent_login?(term(), keyword()) :: boolean()
  def agent_login?(login, opts) when is_binary(login) do
    opts
    |> codeowners_classification_opts()
    |> Keyword.get(:agent_logins, [])
    |> Enum.member?(login)
  end

  def agent_login?(_login, _opts), do: false
end
