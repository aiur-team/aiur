defmodule Aiur.BuildOrder.FeatureDefaults do
  @moduledoc false

  @defaults %{
    "build-queue" => {"queue-list", "Keep the agent pool supplied with unblocked work.", 0},
    "home" => {"home", "Show the platform program and its Build Order work clearly.", 0},
    "refactor-units" => {"wrench-screwdriver", "Refactor units U0–U7 and U9 into reusable components.", 1},
    "size-reduction" => {"scissors", "Reduce module size while preserving the component boundaries.", 1},
    "component-map" => {"cpu-chip", "Define the component map and modular kernel boundaries.", 1},
    "event-bus" => {"arrows-right-left", "Export and consume durable events across components.", 1},
    "auth-independence" => {"shield-check", "Keep component authentication independent of GitHub.", 1},
    "webhook-ingress" => {"link", "Add optional webhook ingress with safe polling fallback.", 1},
    "voice-port" => {"speaker-wave", "Move voice support behind a reusable component boundary.", 1},
    "device-contracts" => {"device-tablet", "Define contracts that work across operator devices.", 1},
    "harness-adapters" => {"puzzle-piece", "Adapt agent harnesses behind shared contracts.", 1},
    "commands" => {"command-line", "Route native questions and Commands to the right responder.", 2},
    "executor" => {"user-circle", "Let the Executor read and send messages from Aiur surfaces.", 3},
    "conversations" => {"chat-bubble-left-right", "Read agent conversations and navigate to event context.", 3},
    "listener" => {"signal", "Choose steer, synchronous, or asynchronous agent delivery.", 3},
    "voice-input" => {"microphone", "Dictate messages and Command responses in the dashboard.", 4},
    "voice-assistant" => {"chat-bubble-bottom-center-text", "Talk with worker agents through a shared voice assistant.", 4},
    "phone-app" => {"device-phone-mobile", "Use one phone app to access Aiur on iOS and Android.", 5},
    "pairing" => {"qr-code", "Pair a phone with a machine and discover its instances.", 5},
    "meta-dashboard" => {"chart-bar", "See instance health and pending Commands before opening it.", 5},
    "push" => {"lock-closed", "Deliver encrypted event notifications to paired devices.", 5},
    "notifications" => {"bell-alert", "Choose device notifications and suppress duplicates.", 5},
    "phone-commands" => {"inbox", "Open a notification in context and answer its Command.", 5},
    "watch-apps" => {"clock", "Read compact status and respond from Apple or Android watches.", 5}
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
