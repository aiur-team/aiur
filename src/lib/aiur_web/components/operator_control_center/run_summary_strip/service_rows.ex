defmodule AiurWeb.OperatorControlCenter.RunSummaryStrip.ServiceRows do
  @moduledoc false

  import AiurWeb.OperatorControlCenter.RunSummaryStrip.Meters, only: [currency_amount: 2, format_used_percent: 1, reset_text: 2]
  alias AiurWeb.RemainingMeter

  # GitHub's two primary budgets, in the order they render. They are separate
  # budgets billed in different units on windows that reset at different times,
  # so every figure on the card belongs to exactly one of them.
  alias AiurWeb.Build.UsageFacts

  @github_resources ~w(core graphql)
  @seconds_per_day 86_400
  @seconds_per_hour 3_600

  @spec api_count_label(boolean()) :: String.t()
  def api_count_label(true), do: "2 APIs"
  def api_count_label(_elevenlabs?), do: "1 API"

  # An unconfigured account is not an API this deployment has: the row is absent
  # entirely. Every other standing — awaiting a first answer, observed, or a
  # failed read against a key that *is* configured — keeps the row, because each
  # of those is a fact about a real account.
  @spec elevenlabs_configured?(map()) :: boolean()
  def elevenlabs_configured?(%{state: :unconfigured}), do: false
  def elevenlabs_configured?(%{state: state}) when state in [:unknown, :observed, :failed], do: true
  def elevenlabs_configured?(_quota), do: false

  @spec elevenlabs_meter_percent(map() | nil) :: number() | nil
  def elevenlabs_meter_percent(%{remaining_percent: percent}) when is_number(percent), do: RemainingMeter.clamp(percent)
  def elevenlabs_meter_percent(%{used_percent: percent}) when is_number(percent), do: RemainingMeter.percent(percent) |> round()
  def elevenlabs_meter_percent(_window), do: nil

  @spec elevenlabs_explanation() :: String.t()
  def elevenlabs_explanation do
    "ElevenLabs account credit quota (characters). Speech-to-text is billed per minute of audio and is not counted here. The dollar figure is the amount due on the next invoice, not a balance."
  end

  # The label already says Credits, so the compact line carries only the
  # remaining count, remaining share, and day-scale reset.
  @spec elevenlabs_meta(map(), DateTime.t()) :: String.t()
  def elevenlabs_meta(%{state: :observed, window: %{} = window}, now) do
    [
      "#{UsageFacts.compact_number(window.remaining)} left",
      elevenlabs_percent_text(window),
      elevenlabs_reset_text(window.reset_at, now)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  def elevenlabs_meta(%{state: :failed, failure: failure}, _now), do: "Unavailable · #{UsageFacts.elevenlabs_failure(failure)}"
  def elevenlabs_meta(_quota, _now), do: "Awaiting ElevenLabs response"

  @spec elevenlabs_compact_meta(map(), DateTime.t()) :: String.t()
  def elevenlabs_compact_meta(%{state: :observed, window: %{} = window}, now) do
    [
      UsageFacts.compact_number(window.remaining),
      elevenlabs_percent_text(window) |> compact_percent_text(),
      elevenlabs_compact_reset_text(window.reset_at, now)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  def elevenlabs_compact_meta(%{state: :failed}, _now), do: "Unavailable"
  def elevenlabs_compact_meta(_quota, _now), do: "Awaiting response"

  defp compact_percent_text(nil), do: nil
  defp compact_percent_text(text), do: text

  defp elevenlabs_compact_reset_text(reset_at, now) do
    reset_at
    |> elevenlabs_reset_text(now)
    |> String.replace_prefix("resets ", "")
  end

  defp elevenlabs_percent_text(%{remaining_percent: percent}) when is_number(percent), do: "#{format_used_percent(RemainingMeter.clamp(percent))}% left"
  defp elevenlabs_percent_text(%{used_percent: percent}) when is_number(percent), do: "#{format_used_percent(RemainingMeter.percent(percent))}% left"
  defp elevenlabs_percent_text(_window), do: nil

  @spec elevenlabs_invoice_due(map() | nil) :: String.t() | nil
  def elevenlabs_invoice_due(%{next_invoice: %{amount_due_cents: cents, currency: currency}})
      when is_integer(cents) and cents >= 0 and is_binary(currency) do
    currency_amount(currency, cents_amount(cents))
  end

  def elevenlabs_invoice_due(_window), do: nil

  defp cents_amount(cents), do: "#{div(cents, 100)}.#{pad2(rem(cents, 100))}"

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp elevenlabs_reset_text(%DateTime{} = reset, %DateTime{} = now) do
    seconds = DateTime.diff(reset, now, :second)

    cond do
      seconds <= 0 -> "reset time passed"
      seconds >= @seconds_per_day -> "resets #{div(seconds, @seconds_per_day)}d"
      seconds >= @seconds_per_hour -> "resets #{div(seconds, @seconds_per_hour)}h"
      true -> "resets #{max(div(seconds, 60), 1)}m"
    end
  end

  defp elevenlabs_reset_text(_reset, _now), do: "reset unavailable"

  @spec github_windows(map()) :: [map()]
  def github_windows(%{windows: windows}) when is_map(windows) do
    @github_resources
    |> Enum.map(&Map.get(windows, &1))
    |> Enum.map(fn window -> if window && Map.has_key?(window, :snapshot_stale?), do: Map.put(window, :snapshot_stale?, true), else: window end)
    |> Enum.reject(&is_nil/1)
  end

  def github_windows(_quota), do: []

  @spec github_backoffs(map()) :: [map()]
  def github_backoffs(%{backoffs: backoffs}) when is_list(backoffs), do: backoffs
  def github_backoffs(_quota), do: []

  @spec github_window_label(map()) :: String.t()
  def github_window_label(%{resource: resource}), do: github_resource_label(resource)

  defp github_resource_label("graphql"), do: "GraphQL"
  defp github_resource_label(resource), do: String.capitalize(resource)

  # GitHub's two budgets bill in different units; the popover names what each
  # window actually meters so "Core"/"GraphQL" are never read as the same thing.
  @spec github_window_explanation(map()) :: String.t() | nil
  def github_window_explanation(%{resource: "core"}), do: "REST request budget"
  def github_window_explanation(%{resource: "graphql"}), do: "GraphQL point budget"
  def github_window_explanation(_window), do: nil

  @spec github_window_meta(map(), DateTime.t()) :: String.t()
  def github_window_meta(window, now) do
    "#{window.remaining}/#{window.limit} left · #{github_percent_text(window)} · #{reset_text(Map.get(window, :reset_at), now)}#{stale_age_text(window, now)}"
  end

  @spec github_window_compact_meta(map(), DateTime.t()) :: String.t()
  def github_window_compact_meta(window, now) do
    "#{window.remaining}/#{window.limit} · #{github_percent_text(window)} · #{compact_reset_text(Map.get(window, :reset_at), now)}#{stale_age_text(window, now)}"
  end

  defp github_percent_text(%{remaining_percent: percent}) when is_number(percent), do: "#{format_used_percent(RemainingMeter.clamp(percent))}% left"
  defp github_percent_text(%{used_percent: percent}) when is_number(percent), do: "#{format_used_percent(RemainingMeter.percent(percent))}% left"
  defp github_percent_text(_window), do: "remaining unknown"

  defp stale_age_text(%{snapshot_stale?: true, observed_at: %DateTime{} = observed_at}, now) do
    age_minutes = max(DateTime.diff(now, observed_at, :minute), 0)
    " · as of #{Calendar.strftime(observed_at, "%H:%MZ")} (#{age_minutes}m ago)"
  end

  defp stale_age_text(_window, _now), do: ""

  defp compact_reset_text(reset_at, now) do
    reset_at
    |> reset_text(now)
    |> String.replace_prefix("resets in ", "")
  end
end
