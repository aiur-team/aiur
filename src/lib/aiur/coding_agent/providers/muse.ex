defmodule Aiur.CodingAgent.Providers.Muse do
  @moduledoc "Native Muse capabilities, discovery and presentation ownership."

  alias Aiur.Config.Schema.MuseBackend
  alias Aiur.Muse.Defaults
  alias Aiur.Muse.ModelCatalog
  alias Aiur.Muse.SessionRecovery
  @spec entry() :: Aiur.CodingAgent.Backend.capabilities()
  def entry do
    %{
      adapter: Aiur.Muse.CodingAgent,
      transcript: Aiur.Muse.Transcript,
      family: "muse",
      configurable: true,
      config_validator: &MuseBackend.validate/1,
      init_order: 5,
      init: Aiur.Muse.Init,
      default_command: Defaults.command(),
      install_hint: "Install Muse CLI and sign in with muse auth before selecting this backend",
      skill_install: %{path: ".agents/skills"},
      model_catalog: &ModelCatalog.extract/1,
      model_probe: &ModelCatalog.probe/2,
      models: ["muse-spark-1.3-contributor"],
      model_aliases: :native,
      efforts: ["minimal", "low", "medium", "high", "xhigh"],
      can_interrupt: true,
      safe_checkpoints: [],
      control_application_confirmation: :confirmed,
      remote_control: false,
      remote_worker: false,
      resumable: true,
      recoverable_session_error: &SessionRecovery.recoverable?/1,
      runtime_report: :headless_wrapper,
      presentation: %{
        order: 5,
        label: "Muse",
        logo: "/provider-assets/muse.svg",
        token_icon: "/provider-assets/muse.svg",
        css_class: "is-muse",
        command_color: "#b5a0ff",
        command_border: "rgba(181, 160, 255, 0.4)",
        unit_color: "#b5a0ff",
        unit_border: "rgba(181, 160, 255, 0.4)",
        unit_background: "rgba(181, 160, 255, 0.12)"
      },
      meter_identity_policy: :host_unverified,
      usage: %{adapters: [Aiur.Usage.Headless.Muse.SessionUsage]},
      account_generation: %{backends: [:app_server], trusted_sources: [], auth_modes: []}
    }
  end
end
