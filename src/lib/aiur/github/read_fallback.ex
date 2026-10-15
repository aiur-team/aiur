defmodule Aiur.GitHub.ReadFallback do
  @moduledoc "Retries watcher reads once with the dedicated CI-readiness credential after auth rejection."

  alias Aiur.GitHub.{Budget, CredentialSelector}

  @watchers ~w(main_watch_ landing_watch_)
  @readiness_env "AIUR_CI_READINESS_TOKEN"

  @spec run(map(), (map() -> term())) :: term()
  def run(request, execute) when is_map(request) and is_function(execute, 1) do
    case execute.(request) do
      {:ok, %{status: 401} = response} -> retry_read(request, response, execute)
      result -> result
    end
  end

  defp retry_read(request, response, execute) do
    case fallback_request(request) do
      {:ok, fallback} -> execute.(fallback) |> annotate_fallback()
      :skip -> {:ok, Map.put(response, :credential, credential_class(request))}
    end
  end

  defp fallback_request(request) do
    with true <- watcher_read?(request),
         token when is_binary(token) <- readiness_token(),
         true <- token != Map.get(request, :token) do
      {:ok,
       Map.merge(request, %{
         token: token,
         credential_id: "ci_readiness",
         credential_class: "ci_readiness_token",
         credential_key: Budget.token_key(token)
       })}
    else
      _ -> :skip
    end
  end

  defp watcher_read?(request) do
    caller = Map.get(request, :caller, "")

    Enum.any?(@watchers, &String.starts_with?(caller, &1)) and
      not Map.get(request, :credential_pinned?, false) and
      CredentialSelector.intent(request) == :read
  end

  defp readiness_token do
    case System.get_env(@readiness_env) do
      token when is_binary(token) -> String.trim(token)
      _ -> ""
    end
  end

  defp annotate_fallback({:ok, %{status: 401} = response}),
    do: {:ok, Map.put(response, :credential, "ci_readiness_token")}

  defp annotate_fallback(result), do: result

  defp credential_class(request), do: Map.get(request, :credential_class, "unknown")
end
