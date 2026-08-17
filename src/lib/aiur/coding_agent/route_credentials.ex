defmodule Aiur.CodingAgent.RouteCredentials do
  @moduledoc """
  Whether a `priority` route can be dispatched at all, given the credentials
  this install actually holds.

  This is the half of #1923's failure semantics that happens *before* a
  request exists. An operator who holds an OpenRouter key but no first-party
  Anthropic key writes `priority: [claude, "openrouter:anthropic/claude-sonnet-5"]`
  and expects the first entry to be quietly stepped over — not to strand every
  claim on a backend that cannot authenticate. So a route whose API-key env var
  is absent is **skipped at selection time**.

  The three deliberate boundaries:

    * **Skipping is silent per claim, announced once per boot.** A missing key
      is a static fact about the install, not an event; alerting on it every
      claim would train the operator to ignore the alert. `log_startup_survey/1`
      names each skipped route and the variable it wants, exactly once, so the
      change from "hard error at dispatch" to "silently not chosen" can never
      happen invisibly.
    * **Every route key-less is a hard error, not an empty fleet.** Silently
      dispatching nothing looks identical to having no work, which is the
      worse failure. `verify_any_usable!/1` raises instead.
    * **A key that is present but rejected is NOT this module's business.**
      That is a 401, handled at request time (`Aiur.CodingAgent.RouteFailure`),
      and it deliberately does not fall through: a broken credential must
      surface, not silently move spend onto a paid path.

  Backends with no `openai_compat` registry entry (claude, codex) authenticate
  through their own CLI rather than an env var aiur can see, so they are always
  considered usable here and fail later if their CLI is not signed in.
  """

  require Logger

  alias Aiur.Config.RoutingValue

  @doc """
  Whether `route` has the credential it needs to be dispatched. `:api_key_fetcher`
  in `opts` overrides the environment lookup, so this is testable without
  mutating the test process's env.
  """
  @spec usable?(String.t(), keyword()) :: boolean()
  def usable?(route, opts \\ []) when is_binary(route) do
    is_nil(missing_key_env(route, opts))
  end

  @doc """
  The API-key env var `route` needs and does not have, or nil when the route is
  usable (including when it needs no env var at all).
  """
  @spec missing_key_env(String.t(), keyword()) :: String.t() | nil
  def missing_key_env(route, opts \\ []) when is_binary(route) do
    fetcher = Keyword.get(opts, :api_key_fetcher, &System.get_env/1)

    case api_key_env(RoutingValue.routing_backend(route)) do
      nil ->
        nil

      env ->
        case fetcher.(env) do
          value when is_binary(value) and value != "" -> nil
          _ -> env
        end
    end
  end

  @doc """
  Logs one line per credential-less route in `routes`. Called once at boot so
  the operator can see why an entry they wrote is never chosen.
  """
  @spec log_startup_survey([String.t()], keyword()) :: :ok
  def log_startup_survey(routes, opts \\ []) when is_list(routes) do
    Enum.each(routes, fn route ->
      case missing_key_env(route, opts) do
        nil ->
          :ok

        env ->
          Logger.info(
            "agent.priority route #{inspect(route)} will be skipped: #{env} is not set. " <>
              "Set it to use this route, or remove the entry to silence this notice."
          )
      end
    end)
  end

  @doc """
  Raises when `routes` is non-empty but not one member has its credential — a
  configured fleet that can dispatch nothing. Surfacing this as a crash is
  deliberate: the silent alternative is indistinguishable from an empty queue.
  """
  @spec verify_any_usable!([String.t()], keyword()) :: :ok
  def verify_any_usable!(routes, opts \\ []) when is_list(routes) do
    if routes == [] or Enum.any?(routes, &usable?(&1, opts)) do
      :ok
    else
      missing = routes |> Enum.map(&missing_key_env(&1, opts)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      raise ArgumentError,
            "every agent.priority route is missing its API key, so no agent can be dispatched. " <>
              "Routes: #{inspect(routes)}; unset variables: #{inspect(missing)}"
    end
  end

  defp api_key_env(nil), do: nil

  defp api_key_env(backend) do
    get_in(Aiur.CodingAgent.backends(), [backend, :openai_compat, :api_key_env])
  end
end
