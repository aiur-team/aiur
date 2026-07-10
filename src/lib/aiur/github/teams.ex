defmodule Aiur.GitHub.Teams do
  @moduledoc """
  GitHub organization team membership domain.
  """

  alias Aiur.GitHub.{Errors, Transport}

  @doc """
  Lists the logins of every member of `team_slug` inside `org`. Used by
  `Aiur.GitHub.CodeOwners` to expand `@org/team` entries.

  Requires the GitHub token to have `read:org` scope; 403 is returned
  otherwise and the caller logs + falls back.
  """
  @spec fetch_team_members(String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_team_members(org, team_slug, opts \\ []) do
    with {:ok, token} <- Transport.require_token() do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Transport.base_url()}/orgs/#{org}/teams/#{team_slug}/members?per_page=100"
      fetch_member_logins(request_fun, token, url, [])
    end
  end

  @spec fetch_member_logins(function(), String.t(), String.t() | nil, [String.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch_member_logins(_request_fun, _token, nil, acc), do: {:ok, acc}

  def fetch_member_logins(request_fun, token, url, acc) do
    case request_fun.(%{method: :get, url: url, token: token}) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_list(body) ->
        new_logins = Enum.flat_map(body, &member_login_list/1)
        next = Transport.parse_next_page_url(headers)
        fetch_member_logins(request_fun, token, next, acc ++ new_logins)

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec member_login_list(map()) :: [String.t()]
  def member_login_list(%{"login" => login}) when is_binary(login), do: [login]
  def member_login_list(_), do: []
end
