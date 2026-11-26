defmodule Aiur.Orchestrator.MergeAttribution do
  alias Aiur.GitHub.Access
  @moduledoc "Resolves merger attribution omitted by sparse GitHub merge events."

  @spec resolve(String.t() | nil, keyword()) :: String.t() | nil
  def resolve(login, _opts) when is_binary(login) and login != "", do: login

  def resolve(_login, opts) do
    with number when is_integer(number) and number > 0 <- Keyword.get(opts, :pr_number),
         {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token(opts) do
      request = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
      url = "#{Access.base_url()}/repos/#{owner}/#{repo}/pulls/#{number}"

      case request.(%{method: :get, url: url, token: token, caller: "merge_attribution"}) do
        {:ok, %{status: 200, body: %{"merged_by" => %{"login" => login}}}} when is_binary(login) and login != "" -> login
        _ -> nil
      end
    else
      _ -> nil
    end
  end
end
