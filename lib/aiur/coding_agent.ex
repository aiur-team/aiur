defmodule Aiur.CodingAgent do
  @moduledoc """
  Adapter boundary for coding agent backends.
  """

  alias Aiur.Config

  @type operator_payload :: %{required(:kind) => :text, required(:body) => String.t()}
  @type safe_checkpoint :: %{required(:kind) => atom(), optional(:method) => String.t()}

  @type checkpoint_callback_result ::
          :noop
          | {:deliver_text, String.t(), (map() -> any()), (term() -> any())}

  @callback start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback run_turn(map(), String.t(), map(), keyword()) ::
              {:ok, map()} | {:paused, map()} | {:error, term()}
  @callback stop_session(map()) :: :ok
  @callback normalize_event(map()) :: map()
  @callback send_operator_message(map(), operator_payload()) ::
              {:ok, request_id :: integer()} | {:error, term()}

  @spec adapter() :: module()
  def adapter do
    case Config.agent_kind() do
      "codex" -> Aiur.Codex.CodingAgent
      _ -> Aiur.Claude.CodingAgent
    end
  end

  @spec start_session(Path.t()) :: {:ok, map()} | {:error, term()}
  @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, opts \\ []), do: adapter().start_session(workspace, opts)

  @spec run_turn(map(), String.t(), map()) :: {:ok, map()} | {:paused, map()} | {:error, term()}
  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:paused, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []), do: adapter().run_turn(session, prompt, issue, opts)

  @spec stop_session(map()) :: :ok
  def stop_session(session), do: adapter().stop_session(session)

  @spec normalize_event(map()) :: map()
  def normalize_event(event), do: adapter().normalize_event(event)

  @spec send_operator_message(map(), operator_payload()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(session, payload), do: adapter().send_operator_message(session, payload)
end
