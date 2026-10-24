defmodule AiurWeb.VoiceTargetResolver do
  @moduledoc """
  Port through which the voice channel asks whether a dictation target can
  still take text.

  Voice input must not depend on the dashboard or Commands, which own the
  running-agent and answerable-Command rules, so the implementation is bound
  by application config (`config :aiur, :voice_target_resolver, Module`) at the
  composition root and resolved per call.
  """

  @type refusal :: :target_not_found | :target_not_writable | :target_stale | :unsupported_target | :unknown

  @doc "Exactly one running agent carries `ticket`."
  @callback worker(ticket :: String.t()) :: :ok | {:error, refusal()}

  @doc "The Command still takes an answer, at `expected_version` when one is given."
  @callback command(decision_id :: String.t(), expected_version :: pos_integer() | nil) :: :ok | {:error, refusal()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:aiur, :voice_target_resolver, __MODULE__.Unbound)

  defmodule Unbound do
    @moduledoc "Used when no component supplies the target rules: no target can be addressed."
    @behaviour AiurWeb.VoiceTargetResolver

    @impl true
    def worker(_ticket), do: {:error, :unsupported_target}

    @impl true
    def command(_decision_id, _expected_version), do: {:error, :unsupported_target}
  end
end
