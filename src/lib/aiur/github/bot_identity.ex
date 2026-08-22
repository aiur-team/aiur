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

  @doc """
  The login the supplied `token` writes as: the configured daemon identity,
  falling back to the token's own viewer login.

  Distinct from `bot_account/3` and not interchangeable with it. Ask this when
  the question is "did the credential I am holding write this comment" — the
  review-thread reply verification does, because the daemon posts those replies
  with the daemon token, and under GitHub App auth that lands as the App bot
  rather than as the account agents publish under.

  The viewer fallback is the same one `bot_account/3` uses and stays correct
  here for the same reason: it reports what this very token authenticates as.
  """
  @spec daemon_account(keyword(), function(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def daemon_account(opts, request_fun, token) do
    case opts
         |> Keyword.get_lazy(:daemon_account, &GitHub.Config.daemon_account/0)
         |> normalize_optional_binary() do
      daemon_account when is_binary(daemon_account) -> {:ok, daemon_account}
      nil -> fetch_authenticated_viewer_login(request_fun, token)
    end
  end

  @spec fetch_authenticated_viewer_login(function(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_authenticated_viewer_login(request_fun, token) do
    case Transport.github_graphql(request_fun, token, @viewer_login_query, %{}, caller: :bot_identity) do
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
    # Every login Aiur itself writes under. Both identities belong here: a
    # comment is "not human review" whether an agent posted it under
    # `bot_account` or the daemon posted it under its GitHub App bot. Listing
    # only one would let the other's comment count as a human's judgement,
    # which is the failure that releases a ticket nobody reviewed.
    # `daemon_account/0` collapses to `bot_account/0` when no App is
    # configured, so a single-identity install yields the same list as before.
    agent_logins =
      [
        Keyword.get_lazy(opts, :bot_account, &GitHub.Config.bot_account/0),
        Keyword.get_lazy(opts, :daemon_account, &GitHub.Config.daemon_account/0)
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
