defmodule SymphonyElixir.CodingAgent do
  @moduledoc """
  Adapter boundary for coding agent backends.
  """

  alias SymphonyElixir.Config

  @callback start_session(Path.t()) :: {:ok, map()} | {:error, term()}
  @callback run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(map()) :: :ok

  @spec adapter() :: module()
  def adapter do
    case Config.agent_kind() do
      "claude" -> SymphonyElixir.Claude.AppServer
      _ -> SymphonyElixir.Codex.AppServer
    end
  end

  @spec start_session(Path.t()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace), do: adapter().start_session(workspace)

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []), do: adapter().run_turn(session, prompt, issue, opts)

  @spec stop_session(map()) :: :ok
  def stop_session(session), do: adapter().stop_session(session)
end
