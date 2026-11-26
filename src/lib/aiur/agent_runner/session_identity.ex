defmodule Aiur.AgentRunner.SessionIdentity do
  @moduledoc false
  @type worker_host :: String.t() | nil

  @doc false
  @spec session_workspace(map()) :: Path.t() | nil
  def session_workspace(%{workspace: workspace}) when is_binary(workspace), do: workspace
  def session_workspace(_session), do: nil

  @doc false
  @spec session_worker_host(map()) :: worker_host()
  def session_worker_host(%{worker_host: worker_host}), do: worker_host
  def session_worker_host(_session), do: nil

  @unknown_backend "unknown"

  @doc """
  The backend that created this session, for paths where a wrong answer
  changes behaviour.

  Raises when the session carries no binary `:backend`, matching
  `Aiur.CodingAgent`'s refusal to dispatch such a session. There is no global
  default here on purpose: `agent.kind` is the configured *default for new
  work*, not evidence about the session in hand, and substituting it made a
  caller-side bug look like a routine run against the wrong provider
  (issue #1621).

  Use `session_backend_label/1` instead on reporting-only paths.
  """
  @spec session_backend!(map()) :: String.t()
  def session_backend!(%{backend: backend}) when is_binary(backend), do: backend

  def session_backend!(session) do
    raise ArgumentError,
          "cannot resolve the coding-agent backend for session #{inspect(session)}; expected a binary :backend"
  end

  @doc """
  The backend that created this session, for reporting only.

  Returns `#{@unknown_backend}` when the session carries no binary `:backend`.
  Alerts, telemetry, and lifecycle records must never take down a turn, so
  they cannot use `session_backend!/1` — but they must not invent a backend
  either. An alert naming the configured default as the provider that hit a
  usage limit is a confidently wrong reason, which costs more to unwind than
  an honest `#{@unknown_backend}`.
  """
  @spec session_backend_label(map()) :: String.t()
  def session_backend_label(%{backend: backend}) when is_binary(backend), do: backend
  def session_backend_label(_session), do: @unknown_backend
end
