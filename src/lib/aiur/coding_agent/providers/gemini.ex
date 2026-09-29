defmodule Aiur.CodingAgent.Providers.Gemini do
  @moduledoc "Native Gemini CLI ACP backend capabilities."

  alias Aiur.Config.Schema.GeminiBackend
  alias Aiur.Gemini.{CodingAgent, Init, ModelCatalog, Transcript}
  alias Aiur.Usage.Headless.Gemini.TurnUsage

  @spec entry() :: map()
  def entry do
    %{
      adapter: CodingAgent,
      transcript: Transcript,
      family: "gemini",
      configurable: true,
      config_validator: &GeminiBackend.validate/1,
      init_order: 6,
      init: Init,
      default_command: "gemini --acp",
      install_hint: "Install and authenticate Gemini CLI, then select gemini",
      skill_install: %{path: ".gemini/skills"},
      model_catalog: &ModelCatalog.extract/1,
      model_probe: &ModelCatalog.probe/2,
      models: [],
      model_aliases: :native,
      efforts: [],
      can_interrupt: true,
      safe_checkpoints: [],
      control_application_confirmation: :request_only,
      remote_control: false,
      remote_worker: false,
      resumable: true,
      runtime_report: :headless_wrapper,
      presentation: %{
        order: 6,
        label: "Gemini",
        logo: "/provider-assets/gemini.svg",
        token_icon: "/provider-assets/gemini.svg",
        css_class: "is-gemini",
        command_color: "#8dbbff",
        command_border: "rgba(141, 187, 255, 0.4)",
        unit_color: "#8dbbff",
        unit_border: "rgba(141, 187, 255, 0.4)",
        unit_background: "rgba(141, 187, 255, 0.12)"
      },
      meter_identity_policy: :host_unverified,
      meter_supported: false,
      usage_backend: :app_server,
      usage_transport: :gemini_acp,
      usage: %{adapters: [TurnUsage]},
      account_generation: %{backends: [], trusted_sources: [], auth_modes: []}
    }
  end
end
