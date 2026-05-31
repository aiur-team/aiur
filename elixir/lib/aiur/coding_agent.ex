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
    adapter_for_kind(Config.agent_kind())
  end

  @doc """
  Resolve the adapter for a specific issue via `complexity:N` label routing.
  Falls back to the global `adapter/0` when the issue is nil, has no
  complexity label, or the routing map has no entry for that complexity.

  `Aiur.AgentRunner` calls this once per session and threads the chosen
  module through `start_session`, `run_turn`, `stop_session`, and the
  transcript extractor so a single session never mixes backends.
  """
  @spec adapter_for(map() | nil) :: module()
  def adapter_for(issue) do
    adapter_for_kind(Config.agent_kind_for_issue(issue))
  end

  @doc """
  Backend-specific module that knows how to turn a raw notification
  message into a transcript event (or skip it). Keeps the codex / Claude
  notification-shape differences out of `Aiur.AgentRunner`. Each module
  exposes `extract(message, fallback_turn_id) :: {:ok, transcript_event} | :skip`.
  """
  @spec transcript_module() :: module()
  def transcript_module do
    transcript_module_for_kind(Config.agent_kind())
  end

  @doc """
  Per-issue transcript module — mirrors `adapter_for/1` so a Claude-routed
  session is parsed with the Claude transcript extractor (and the same for
  Codex). Falls back to the global default when routing is absent.
  """
  @spec transcript_module_for(map() | nil) :: module()
  def transcript_module_for(issue) do
    transcript_module_for_kind(Config.agent_kind_for_issue(issue))
  end

  @doc """
  Single-snapshot resolver — returns `{adapter, transcript_module}` from
  one `Config.agent_kind_for_issue/1` call so the pair always comes from
  the same workflow snapshot. Calling `adapter_for/1` and
  `transcript_module_for/1` independently risks a workflow reload landing
  between them and pinning a Claude adapter with the Codex transcript
  module (or vice versa). `Aiur.AgentRunner.run_codex_turns/5` uses this
  to lock the pair atomically at session start.
  """
  @spec modules_for(map() | nil) :: {module(), module()}
  def modules_for(issue) do
    kind = Config.agent_kind_for_issue(issue)
    {adapter_for_kind(kind), transcript_module_for_kind(kind)}
  end

  defp adapter_for_kind("codex"), do: Aiur.Codex.CodingAgent
  defp adapter_for_kind(_), do: Aiur.Claude.CodingAgent

  defp transcript_module_for_kind("codex"), do: Aiur.Codex.Transcript
  defp transcript_module_for_kind(_), do: Aiur.Claude.Transcript

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
