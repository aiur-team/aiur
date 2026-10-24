defmodule Aiur.BuildOrder.FeatureDefaults do
  @moduledoc false

  @defaults %{
    "build-queue" => {"queue-list", "Keep the agent pool supplied with unblocked work.", 0},
    "home" => {"home", "Show the platform program and its Build Order work clearly.", 0},
    "refactor-units" => {"wrench-screwdriver", "Refactor units U0–U7 and U9 into reusable components.", 1},
    "size-reduction" => {"scissors", "Reduce module size while preserving the component boundaries.", 1},
    "kernel" => {"cpu-chip", "Define the component map and modular kernel boundaries.", 1},
    "event-bus" => {"arrows-right-left", "Export and consume durable events across components.", 1},
    "voice" => {"speaker-wave", "Move voice support behind a reusable component boundary.", 1},
    "harness" => {"puzzle-piece", "Adapt agent harnesses behind shared contracts.", 1},
    "command-delivery" => {"command-line", "Route native questions and Commands to the right responder.", 2},
    "executor" => {"user-circle", "Let the Executor read and send messages from Aiur surfaces.", 3},
    "conversations" => {"chat-bubble-left-right", "Read agent conversations and navigate to event context.", 3}
  }

  @spec get(term()) :: map()
  def get(id) when is_binary(id) do
    case Map.get(@defaults, id) do
      {icon, summary, wave} -> %{"icon" => icon, "summary" => summary, "wave" => wave}
      nil -> %{}
    end
  end

  def get(_id), do: %{}

  @spec all() :: map()
  def all, do: @defaults
end
