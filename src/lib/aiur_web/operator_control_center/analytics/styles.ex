defmodule AiurWeb.OperatorControlCenter.Analytics.Styles do
  @moduledoc """
  The one analytics stylesheet, shared by the live-session page and the Build
  Order pane.

  Everything is scoped under `.analytics-root` rather than a page id so both
  surfaces get identical cards, KPI tiles, and series colours from a single
  definition — the two scopes differ in what they measure, not in how they look.
  """

  @doc "Inline CSS for any element carrying the `analytics-root` class."
  @spec css() :: String.t()
  def css do
    """
    .analytics-root{
      --an-mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
      --an-s1:#3987e5;--an-s2:#008300;--an-s3:#d55181;--an-s4:#c98500;
      --an-s5:#199e70;--an-s6:#d95926;--an-s7:#9085e9;--an-s8:#e66767;
    }
    html[data-theme="light"] .analytics-root{
      --an-s1:#2a78d6;--an-s2:#008300;--an-s3:#e87ba4;--an-s4:#eda100;
      --an-s5:#1baf7a;--an-s6:#eb6834;--an-s7:#4a3aa7;--an-s8:#e34948;
    }
    .analytics-root{display:flex;flex-direction:column;gap:1rem}
    .an-controls{display:flex;justify-content:space-between;align-items:center;gap:1rem}
    .an-scope{display:inline-flex;align-items:center;gap:.4rem;font-family:var(--an-mono);font-size:.68rem;font-weight:600;color:var(--muted)}
    .an-scope b{color:var(--fg);font-weight:700}
    .an-scope-note{font-size:.72rem;color:var(--faint);margin:0}
    .an-kpis{display:grid;grid-template-columns:repeat(6,1fr);gap:.7rem}
    .an-kpi{border:1px solid var(--line);border-radius:var(--radius);background:var(--surface);box-shadow:var(--shadow-sm);padding:.85rem .95rem;display:flex;flex-direction:column;gap:.15rem}
    .an-kpi-label{font-family:var(--an-mono);font-size:.62rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:var(--muted)}
    .an-kpi-val{font-family:var(--an-mono);font-size:1.5rem;font-weight:700;letter-spacing:-.02em;color:var(--fg);line-height:1.05}
    .an-kpi-sub{font-size:.72rem;color:var(--faint)}
    .an-kpi.block .an-kpi-val{color:var(--blocking-ink)}
    .an-grid{display:grid;grid-template-columns:1fr 1fr;gap:1rem;align-items:start}
    .an-card{border:1px solid var(--line);border-radius:var(--radius);background:var(--surface);box-shadow:var(--shadow-sm);padding:1rem 1.1rem .9rem;display:flex;flex-direction:column;min-width:0}
    .an-card.wide{grid-column:1 / -1}
    .an-card.scroll .an-chart{max-height:440px;overflow-y:auto;overflow-x:hidden}
    .an-card-head{display:flex;align-items:flex-start;justify-content:space-between;gap:1rem;margin-bottom:.7rem}
    .an-card-title{margin:0;font-size:.98rem;font-weight:700;color:var(--fg);letter-spacing:-.01em}
    .an-card-sub{margin:.2rem 0 0;font-size:.78rem;line-height:1.4;color:var(--muted);max-width:64ch}
    .an-chart{width:100%;min-width:0}
    .an-zoombar{display:flex;align-items:center;justify-content:space-between;gap:.65rem;border:1px solid var(--accent-line);border-radius:var(--radius);background:var(--accent-soft);padding:.45rem .65rem;color:var(--accent-ink);font-family:var(--an-mono);font-size:.68rem;font-weight:600}
    .an-zoombar button{appearance:none;border:1px solid var(--accent-line);border-radius:999px;background:var(--surface);color:var(--accent-ink);font:inherit;font-weight:700;padding:.18rem .55rem;cursor:pointer}
    .an-zoombar button:hover{border-color:var(--accent-ink)}
    .an-seg{display:inline-flex;border:1px solid var(--line);border-radius:999px;overflow:hidden;flex:none}
    .an-seg button{appearance:none;border:0;background:transparent;color:var(--muted);font-family:var(--an-mono);font-size:.68rem;font-weight:600;padding:.3rem .6rem;cursor:pointer;border-right:1px solid var(--line)}
    .an-seg button:last-child{border-right:0}
    .an-seg button.on{background:var(--accent-soft);color:var(--accent-ink)}
    .an-legend{border-top:1px solid var(--hairline);margin-top:.6rem;padding-top:.7rem}
    .an-legend-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:.55rem}
    .an-legend-title{font-family:var(--an-mono);font-size:.66rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:var(--muted)}
    .an-legend-acts{display:flex;gap:.35rem}
    .an-lg-btn{appearance:none;border:1px solid var(--line);background:transparent;color:var(--muted);font-family:var(--an-mono);font-size:.66rem;font-weight:600;padding:.2rem .55rem;border-radius:999px;cursor:pointer}
    .an-lg-btn:hover{color:var(--fg);border-color:var(--line-strong)}
    .an-chips{display:flex;flex-wrap:wrap;gap:.3rem}
    .an-chip{display:inline-flex;align-items:center;gap:.3rem;border:1px solid var(--line);background:var(--pill-bg);color:var(--faint);font-family:var(--an-mono);font-size:.68rem;font-weight:600;padding:.16rem .42rem;border-radius:7px;cursor:pointer}
    .an-chip i{width:8px;height:8px;border-radius:2px;opacity:.35;flex:none}
    .an-chip.on{color:var(--fg);border-color:var(--line-strong)}
    .an-chip.on i{opacity:1}
    .an-chip:hover{border-color:var(--accent-line)}
    .an-empty{border:1px dashed var(--line-strong);border-radius:var(--radius);background:var(--surface);padding:2.4rem;text-align:center;color:var(--muted)}
    .an-empty b{color:var(--fg)}
    @media(max-width:1080px){.an-kpis{grid-template-columns:repeat(3,1fr)}.an-grid{grid-template-columns:1fr}.an-card.wide{grid-column:auto}}
    @media(max-width:560px){.an-kpis{grid-template-columns:repeat(2,1fr)}.an-card-head{flex-direction:column}}
    """
  end
end
