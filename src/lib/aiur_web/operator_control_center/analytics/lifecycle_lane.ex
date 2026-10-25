defmodule AiurWeb.OperatorControlCenter.Analytics.LifecycleLane do
  @moduledoc "Renders work and PR milestones on an analytics ticket lane."

  @spec render(map(), {integer(), integer()}, (integer() -> number()), number(), String.t()) :: String.t()
  def render(r, {t0, t1}, xf, y, color) do
    work_bar =
      if r.work_ms < t1 do
        bx = r2(xf.(r.work_ms))
        bw = r2(max(xf.(r.end_ms) - xf.(r.work_ms), 2))
        ~s|<rect x="#{bx}" y="#{r2(y + 3)}" width="#{bw}" height="10" rx="3" fill="#{color}" fill-opacity="0.85"/>|
      else
        ""
      end

    end_marker =
      if r.end_ms >= t0 and r.end_ms <= t1 do
        ~s|<circle cx="#{r2(xf.(r.end_ms))}" cy="#{r2(y + 9)}" r="3" fill="#{color}" stroke="var(--surface)" stroke-width="1"/>|
      else
        ""
      end

    work_bar <> end_marker <> pr_opened_marker(Map.get(r, :pr_opened_at), {t0, t1}, xf, y)
  end

  defp pr_opened_marker(at, {t0, t1}, xf, y) when is_integer(at) and at >= t0 and at <= t1 do
    x = r2(xf.(at))
    ~s|<line class="an-pr-opened" x1="#{x}" x2="#{x}" y1="#{y + 1}" y2="#{y + 15}" stroke="var(--attention)" stroke-width="2"><title>PR opened</title></line>|
  end

  defp pr_opened_marker(_at, _window, _xf, _y), do: ""
  defp r2(v), do: Float.round(v * 1.0, 2)
end
