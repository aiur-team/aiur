defmodule Aiur.OpenAICompat.Registry do
  @moduledoc false

  alias Aiur.OpenAICompat.ProviderMeterProbe

  @spec entries() :: %{String.t() => Aiur.CodingAgent.Backend.capabilities()}
  def entries do
    %{
      "kimi" =>
        entry("kimi", %{
          rate_limit_fallback_target: true,
          configurable: true,
          init_order: 2,
          models: ["kimi-k2.7-code", "kimi-k2.7-code-highspeed"],
          openai_compat: %{
            base_url: "https://api.moonshot.ai/v1",
            api_key_env: "MOONSHOT_API_KEY",
            default_model: "kimi-k2.7-code",
            transport: :chat_completions,
            quirks: %{reasoning_content_replay: true}
          },
          presentation:
            presentation(
              2,
              "Kimi",
              "kimi",
              "#74d9e8",
              "rgba(116, 217, 232, 0.4)",
              "rgba(116, 217, 232, 0.12)"
            ),
          usage: %{adapters: [Aiur.Usage.Headless.Kimi.RequestUsage]},
          account_generation: account_generation(:kimi)
        }),
      "deepseek" =>
        entry("deepseek", %{
          rate_limit_fallback_target: false,
          configurable: false,
          dispatch_enabled_by_default: false,
          init_order: 3,
          models: ["deepseek-v4-flash"],
          openai_compat: %{
            base_url: "https://api.deepseek.com",
            api_key_env: "DEEPSEEK_API_KEY",
            default_model: "deepseek-v4-flash",
            transport: :responses,
            quirks: %{
              reasoning_content_replay: true,
              text_tool_fallback: true,
              local_concurrency_limit: true
            }
          },
          presentation:
            presentation(
              3,
              "DeepSeek",
              "deepseek",
              "#6f9cff",
              "rgba(111, 156, 255, 0.4)",
              "rgba(111, 156, 255, 0.12)"
            ),
          usage: %{adapters: [Aiur.Usage.Headless.DeepSeek.RequestUsage]},
          account_generation: account_generation(:deepseek)
        }),
      "openrouter" =>
        entry("openrouter", %{
          rate_limit_fallback_target: true,
          configurable: true,
          init_order: 4,
          models: [
            "deepseek/deepseek-v4-flash",
            "moonshotai/kimi-k2.7-code",
            "anthropic/claude-sonnet-5",
            "anthropic/claude-opus-5"
          ],
          openai_compat: %{
            base_url: "https://openrouter.ai/api/v1",
            api_key_env: "OPENROUTER_API_KEY",
            management_api_key_env: "OPENROUTER_MANAGEMENT_KEY",
            transport: :chat_completions,
            quirks: %{openrouter_metadata: true}
          },
          presentation:
            presentation(
              4,
              "OpenRouter",
              "openrouter",
              "#b59cff",
              "rgba(181, 156, 255, 0.4)",
              "rgba(181, 156, 255, 0.12)"
            ),
          usage: %{adapters: [Aiur.Usage.Headless.OpenRouter.RequestUsage]},
          account_generation: account_generation(:openrouter)
        })
    }
  end

  defp entry(family, overrides) do
    Map.merge(
      %{
        adapter: Aiur.OpenAICompat.CodingAgent,
        transcript: Aiur.OpenAICompat.Transcript,
        family: family,
        can_interrupt: false,
        safe_checkpoints: [:notification, :tool_result],
        control_application_confirmation: :request_only,
        remote_control: false,
        resumable: false,
        remote_worker: false,
        model_aliases: :native,
        efforts: [],
        pricing: pricing(),
        meter_probe: &ProviderMeterProbe.probe/3,
        usage_backend: :openai_compat,
        usage_transport: :openai_compat
      },
      overrides
    )
  end

  defp presentation(order, label, slug, color, border, background) do
    %{
      order: order,
      label: label,
      logo: "/provider-assets/#{slug}.svg",
      token_icon: "/provider-assets/#{slug}-token.svg",
      css_class: "is-#{slug}",
      command_color: color,
      command_border: border,
      unit_color: color,
      unit_border: border,
      unit_background: background
    }
  end

  defp pricing do
    %{
      dimensions: %{
        context_tier: %{
          allowed: [:not_applicable],
          default: :not_applicable,
          required: false
        },
        cache_write_duration: %{
          allowed: [:not_applicable],
          default: :not_applicable,
          required: false
        }
      },
      component_dimensions: %{
        default: %{
          context_tier: [:not_applicable],
          cache_write_duration: [:not_applicable]
        }
      }
    }
  end

  defp account_generation(provider) do
    %{
      backends: [:openai_compat],
      trusted_sources: [trusted_key_source(provider), trusted_api_source(provider)],
      auth_modes: ["api_key"]
    }
  end

  defp trusted_key_source(:kimi), do: :kimi_api_key
  defp trusted_key_source(:deepseek), do: :deepseek_api_key
  defp trusted_key_source(:openrouter), do: :openrouter_api_key
  defp trusted_api_source(:kimi), do: :kimi_api
  defp trusted_api_source(:deepseek), do: :deepseek_api
  defp trusted_api_source(:openrouter), do: :openrouter_api
end
