defmodule Aiur.CodingAgent.Providers.Fake do
  @moduledoc "Test-only registry definition used to exercise provider consumers."

  @spec entry() :: Aiur.CodingAgent.Backend.capabilities()
  def entry do
    %{
      adapter: Aiur.Codex.CodingAgent,
      transcript: Aiur.Codex.Transcript,
      family: "fake",
      skill_install: %{path: ".fake/skills"},
      rate_limit_fallback_target: true,
      configurable: true,
      init_order: 99,
      default_command: "fake-agent --serve",
      models: ["fake-1"],
      model_aliases: :native,
      efforts: [],
      can_interrupt: false,
      safe_checkpoints: [],
      control_application_confirmation: :confirmed,
      remote_control: false,
      resumable: false,
      presentation: %{
        order: 99,
        label: "Fake",
        logo: "/provider-assets/codex-color.svg",
        token_icon: "/provider-assets/codex-token.svg",
        css_class: "is-fake",
        command_color: "#8fbcff",
        command_border: "rgba(143, 188, 255, 0.4)",
        unit_color: "#8fbcff",
        unit_border: "rgba(143, 188, 255, 0.4)",
        unit_background: "rgba(143, 188, 255, 0.12)"
      },
      pricing: %{
        dimensions: %{
          context_tier: %{allowed: [:not_applicable], default: :not_applicable, required: false},
          cache_write_duration: %{allowed: [:not_applicable], default: :not_applicable, required: false}
        },
        component_dimensions: %{default: %{context_tier: [:not_applicable], cache_write_duration: [:not_applicable]}}
      },
      usage: %{adapters: [Aiur.Usage.Headless.Fake.RequestUsage]},
      account_generation: %{backends: [:app_server], trusted_sources: [:fake_app_server], auth_modes: ["fake"]}
    }
  end
end
