defmodule AiurWeb.Experiments.Styles do
  @moduledoc false
  @spec css() :: String.t()
  def css do
    """
    .exp-root{--an-s1:#3987e5;--an-s2:#008300;--an-s3:#d55181;--an-s4:#c98500}
    [data-theme=dark] .exp-root{--an-s1:#2a78d6;--an-s2:#008300;--an-s3:#e87ba4;--an-s4:#eda100}
    #exp-charts{min-width:0;max-width:100%}#exp-charts svg{display:block;color:var(--fg);overflow:hidden}
    .exp-metric-links,.exp-strata{display:flex;flex-wrap:wrap;gap:8px;margin:16px 0}
    .exp-metric-links a,.exp-strata a{display:flex;align-items:center;min-height:44px;padding:8px 12px;color:var(--fg);border:1px solid var(--line);border-radius:4px}
    #exp-charts a[aria-current=true]{border-color:var(--accent-ink);text-decoration:underline}
    .exp-metric-select{display:none}.exp-metric-select select{max-width:100%;min-height:44px;color:var(--fg);background:var(--surface)}
    .exp-series-scroll,.exp-data-scroll{max-width:100%;overflow-x:auto}.exp-series-canvas{min-width:560px}
    #exp-charts summary{cursor:pointer;min-height:44px;display:flex;align-items:center}
    #exp-charts table{width:100%;border-collapse:collapse}#exp-charts td,#exp-charts th{padding:8px;text-align:left;border-bottom:1px solid var(--line);white-space:nowrap}
    .exp-grid{opacity:.15}.exp-zero{stroke-dasharray:4 4}.exp-ci{stroke-width:3}.exp-hollow circle{fill:none;stroke:var(--fg)}.exp-estimate circle{fill:var(--fg)}
    .exp-expected{fill:var(--accent);opacity:.12}.exp-box{fill:var(--surface-2);stroke:var(--muted)}
    .exp-point{stroke:var(--fg);stroke-width:.5}.exp-series-0{fill:var(--an-s1)}.exp-series-1{fill:var(--an-s2)}.exp-series-2{fill:var(--an-s3)}.exp-series-3{fill:var(--an-s4)}
    .exp-before{fill:var(--faint)}.exp-after{fill:var(--accent)}
    .exp-outside{fill:none;stroke-dasharray:2 2}.exp-window-shade{fill:var(--faint);opacity:.15}.exp-window-after{fill:var(--accent)}.exp-frozen{stroke:var(--fg);stroke-width:2;stroke-dasharray:5 3}
    .exp-meter-track{fill:var(--line)}.exp-meter-fill{fill:var(--accent-ink)}
    @media(max-width:959px){.exp-metric-links{display:none}.exp-metric-select{display:block}.exp-metric-select label{display:block}}
    .exp-root{min-width:0;color:var(--fg)}
    .exp-layout{display:grid;grid-template-columns:300px minmax(0,1fr);gap:24px}
    .exp-index,.exp-detail{min-width:0;overflow-wrap:anywhere}
    .exp-link{display:block;min-height:44px;padding:14px 16px;border:1px solid var(--line);border-left:3px solid transparent;border-radius:8px;margin-bottom:8px;color:var(--fg);text-decoration:none;background:var(--surface)}
    .exp-link[aria-current=page]{border-left-color:var(--accent-ink);background:var(--surface-2)}
    .exp-link:focus-visible,.exp-back:focus-visible{outline:2px solid var(--fg);outline-offset:3px}
    .exp-chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px;font-size:12px;color:var(--muted)}
    .exp-chip{padding:3px 7px;border:1px solid var(--line);border-radius:4px}
    .exp-notice{padding:16px;border:1px solid var(--line);border-radius:8px;margin:16px 0;color:var(--muted)}
    .exp-detail h2{margin-top:0}.exp-detail dl{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:8px 16px}
    .exp-window{display:contents}.exp-detail dd{margin:0}.exp-detail dt{color:var(--muted)}
    .exp-table{width:100%;border-collapse:collapse;table-layout:fixed}
    .exp-table th,.exp-table td{text-align:left;padding:12px;border-bottom:1px solid var(--line);overflow-wrap:anywhere}
    .exp-back{display:none;min-height:44px;align-items:center;color:var(--fg)}
    @media(max-width:959px){.exp-layout{display:block}.exp-root[data-selection=detail] .exp-index{display:none}.exp-root[data-selection=index] .exp-detail{display:none}.exp-back{display:flex}.exp-detail dl{grid-template-columns:1fr}.exp-window{display:contents}.exp-detail dd{margin-bottom:8px}.exp-table thead{display:none}.exp-table tr,.exp-table td{display:block}.exp-table tr{margin-bottom:16px;border:1px solid var(--line);border-radius:8px}.exp-table td::before{content:attr(data-label) ": ";color:var(--muted)}}
    """
  end
end
