defmodule AiurWeb.Experiments.Styles do
  @moduledoc false
  @spec css() :: String.t()
  def css do
    """
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
