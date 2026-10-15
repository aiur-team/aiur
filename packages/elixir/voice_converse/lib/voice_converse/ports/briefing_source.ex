defmodule VoiceConverse.Ports.BriefingSource do
  @moduledoc "Required port: what is going on with a target. A target is an opaque host term."

  alias VoiceConverse.Briefing

  @callback describe_target(target :: term()) :: %{id: term(), kind: term(), title: String.t()}
  @callback brief(target :: term()) :: {:ok, Briefing.t()} | {:error, :unavailable}
  @callback details(target :: term(), section :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback sections(target :: term()) :: [%{id: String.t(), description: String.t()}]
  @callback subscribe(target :: term(), pid()) :: :ok | :unsupported
  @callback alive?(target :: term()) :: boolean() | :unknown
end
