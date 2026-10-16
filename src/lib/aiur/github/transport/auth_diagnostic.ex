defmodule Aiur.GitHub.Transport.AuthDiagnostic do
  @moduledoc false

  alias Aiur.GitHub.{CredentialSelector, QueueCost}

  require Logger

  @spec run(map(), (map() -> term())) :: term()
  def run(request, execute) do
    selector_opts = Application.get_env(:aiur, :github_credential_selector_options, [])
    request = request |> QueueCost.tag() |> CredentialSelector.assign(selector_opts)
    request |> execute.() |> annotate(request)
  end

  @spec annotate(term(), map()) :: term()
  def annotate({:ok, %{status: 401} = response}, request) do
    credential = Map.get(request, :credential_class, "unregistered_token")
    log_once(request, credential)
    {:ok, Map.put(response, :credential, credential)}
  end

  def annotate(result, _request), do: result

  defp log_once(request, credential) do
    url = URI.parse(Map.get(request, :url, ""))
    token = Map.get(request, :token, "")
    digest = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    method = request |> Map.get(:method, :unknown) |> to_string() |> String.upcase()
    credential_id = Map.get(request, :credential_id, "unregistered")
    key = {__MODULE__, :unauthorized, credential_id, credential, method, url.host, url.path, digest}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "github_request_unauthorized method=#{method} host=#{url.host || "unknown"} path=#{url.path || "/"} " <>
          "credential_id=#{credential_id} credential_class=#{credential} auth_bytes=#{byte_size(token)} auth_sha256_prefix=#{digest}"
      )
    end
  end
end
