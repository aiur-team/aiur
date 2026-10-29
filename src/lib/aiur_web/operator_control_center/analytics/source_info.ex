defmodule AiurWeb.OperatorControlCenter.Analytics.SourceInfo do
  @moduledoc false

  @spec for_model(map(), DateTime.t()) :: map()
  def for_model(model, now) do
    boot_id = Map.get(model, :source_boot_id)
    observed_at = parse_observed(Map.get(model, :source_observed_at))
    age_ms = if observed_at, do: max(DateTime.diff(now, observed_at, :millisecond), 0), else: nil

    %{kind: source_kind(boot_id, safe_boot_id()), boot_id: boot_id, observed_at: observed_at, age_ms: age_ms}
  end

  defp source_kind(boot_id, current) when is_binary(boot_id) and boot_id != "" and boot_id == current, do: :live
  defp source_kind(boot_id, _current) when is_binary(boot_id) and boot_id != "", do: :retained
  defp source_kind(_boot_id, _current), do: :history

  defp parse_observed(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, observed_at, _offset} -> observed_at
      _invalid -> nil
    end
  end

  defp parse_observed(_other), do: nil

  defp safe_boot_id do
    Aiur.RunTelemetry.boot_id()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end
end
