import csv,collections,pathlib
base=pathlib.Path(__file__).resolve().parents[1]
old={r['path']:r for r in csv.DictReader(open(base/'oversized-file-owner-map.csv'))}
cur=list(csv.DictReader(open(base/'file-size-census-release-007.csv')))
ids={}
overrides={
 'src/lib/aiur.ex':'APP_BOOT',
 'src/test/aiur/application_test.exs':'APP_BOOT',
 'src/test/aiur/app_server_test.exs':'AGENT_TURN',
 'src/test/aiur/app_server/adapter_test.exs':'AGENT_TURN',
 'docs/design/streamdeck/streamdeck.design.js':'DECK_DESIGN',
 'src/test/aiur_web/github_webhook_test.exs':'EVENTS',
 'src/test/aiur/agent_list/app_test.exs':'OPENCODE',
 'src/test/aiur/agent_list/renderer_test.exs':'OPENCODE',
 'src/test/aiur/dynamic_tool_test.exs':'CODEX',
 'src/test/aiur/aiur_agent_skill_test.exs':'SKILLS',
 'src/test/manual/executor_control_center_docs_fixture.exs':'BROWSER',
}
def assign(p,o):
 if p in overrides:return overrides[p]
 if p.startswith('docs/plans/') or p.startswith('docs/brainstorms/'): return 'HIST_CE'
 if p.startswith('src/docs/'): return 'HIST_PRODUCT'
 if p.startswith('.claude/skills/ce-'): return 'CE'
 if p.startswith('.claude/skills/aiur-build/scripts/publication/'): return 'BO_PUBLISH'
 if p.startswith('.claude/skills/aiur-') or p.startswith('.codex/skills/'): return 'SKILLS'
 if p.startswith('docs/build-order/prototype/') or p in ['docs/build-order/plan-preview.html','docs/build-order/AGENT-CHAT.md','docs/build-order/EXECUTOR-HANDOFF.md']: return 'BO_DESIGN'
 if p.startswith('docs/build-order/') or p.startswith('src/priv/build_orders/'): return 'BO_PUBLISH'
 if p.startswith('src/lib/aiur/build_order/') or p.startswith('src/test/aiur/build_order/') or '/build_order/' in p or 'build_order' in p or 'planning_source' in p: return 'BO_RUNTIME'
 if p.startswith('src/priv/static/vendor/elk/') or 'layout-worker' in p: return 'LAYOUT'
 if p.startswith('packages/streamdeck/') or p.startswith('docs/design/streamdeck/'): return 'DECK_PKG'
 if 'streamdeck' in p or 'stream_deck' in p: return 'DECK_WEB'
 if p.startswith('src/browser/') or p.startswith('src/test/browser/') or p.startswith('src/priv/static/'): return 'BROWSER'
 if p.startswith('website/docs-app/'): return 'DOCS'
 if p.startswith('website/'): return 'SITE'
 if p.startswith('analytics/') or '/fixtures/analytics/' in p: return 'ANALYTICS'
 if p.startswith('.github/'): return 'CI'
 if p.startswith('src/priv/github_') or 'github_guard' in p or 'github_client' in p: return 'GH_GUARD'
 if p.startswith('src/lib/aiur/github/') or p.startswith('src/test/aiur/github/') or p in ['src/lib/aiur/codeowners.ex','src/test/aiur/regression/github_ingestion_test.exs'] or 'github_webhook' in p and p.startswith('src/test/aiur_web/'):
  return 'GH_TRUST' if any(t in p for t in ['codeowners','authorization','auth_preflight','config','dispatch_','issues','issue_state']) else 'GH_ACCESS'
 if p.startswith('src/lib/aiur/events/') or p.startswith('src/test/aiur/events/') or p in ['src/lib/aiur/executor_events.ex','src/lib/aiur/executor_wake_inbox.ex','src/lib/aiur/alerts.ex','src/test/aiur/alerts_test.exs','src/lib/aiur/webhooks/mode_registry.ex']: return 'EVENTS'
 if 'decision' in p: return 'DECISIONS'
 if p.startswith('src/lib/aiur/orchestrator/') or p.startswith('src/test/aiur/orchestrator/') or p.startswith('src/test/aiur/orchestrator_') or p in ['src/lib/aiur/orchestrator.ex','src/test/aiur/regression/orchestrator_lifecycle_test.exs','src/test/aiur/regression/orchestrator_blocking_http_test.exs']:
  return 'LIFECYCLE_STATUS' if any(t in p for t in ['status','snapshot','reconciler','ci_lifecycle','control_lifecycle','pause_resume','auto_resume','orphaned','rework_','deactivate','current_run']) else 'LIFECYCLE_DISPATCH'
 if p.startswith('src/lib/aiur/agent_runner') or p.startswith('src/test/aiur/agent_runner') or p.startswith('src/lib/aiur/agent_queue') or p.startswith('src/test/aiur/agent_queue'): return 'AGENT_TURN'
 if p.startswith('src/lib/aiur/claude/') or p.startswith('src/test/aiur/claude/'): return 'CLAUDE'
 if p.startswith('src/lib/aiur/codex/') or p.startswith('src/test/aiur/codex/'): return 'CODEX'
 if p.startswith('src/lib/aiur/opencode/') or p.startswith('src/test/aiur/opencode/') or 'pane_' in p or p in ['src/lib/aiur/tmux.ex','src/lib/aiur/live_conversation.ex','src/test/aiur/live_conversation_test.exs','src/test/aiur/live_e2e_test.exs']: return 'OPENCODE'
 if p.startswith('src/lib/aiur/decision'): return 'DECISIONS'
 if p.startswith('src/lib/aiur/run_telemetry/') or p.startswith('src/test/aiur/run_telemetry/') or 'usage' in p or 'provider_meter' in p or 'provider_account' in p: return 'TELEMETRY'
 if p.startswith('src/lib/aiur_web/') or p.startswith('src/test/aiur_web/'): return 'WEB'
 if p.startswith('packaging/npm/') or p.startswith('scripts/aiurdev') or 'aiur_engine' in p or 'scripts_aiurdev' in p: return 'CLI'
 if 'build_gate' in p or p.startswith('src/priv/build_gate'): return 'BUILD_GATE'
 if 'workspace' in p or 'repo_base' in p: return 'WORKSPACE'
 if 'config' in p or p.endswith('/init_test.exs') or p.endswith('/env_test.exs'): return 'CONFIG'
 if p.startswith('src/test/support/') or p.startswith('src/test/manual/'): return 'TEST_HARNESS'
 if p=='src/lib/aiur/linear/client.ex': return 'LINEAR'
 if p.startswith('src/lib/aiur/') or p.startswith('src/test/aiur/') or p=='src/lib/aiur.ex':
  if any(t in p for t in ['agent_control','cli_test','/cli.ex','engine_control']): return 'CLI'
  if any(t in p for t in ['current_run','ticket_activity','issue_log','open_ticket','recent_merge','progress_retention','workflow_store','coordination_tasks']): return 'LIFECYCLE_STATUS'
  if any(t in p for t in ['coding_agent','dynamic_tool','agent_environment','model_discovery','agent_list','agent_log','agent_process_log','aiur_agent_skill','open_ai_compat']): return 'AGENT_CORE'
  if any(t in p for t in ['test_reset','core_test','extensions_test','app_server','application_test','/aiur.ex','/webhooks/']): return 'TEST_HARNESS'
  return 'TEST_HARNESS'
 if p in ['AGENTS.md','SPEC.md','src/README.md']: return 'DOCS'
 return 'UNMAPPED'
for r in cur:
 p=r['path']; o=old.get(p,{}).get('proposed_owner','NEW'); ids[p]=assign(p,o)
assert len(cur)==357 and len(ids)==357, 'release census has missing or duplicate paths'
assert len(set(ids)&set(old))==355, 'frozen owner survivors changed'
assert len(set(ids)-set(old))==2, 'new release owners changed'
assert 'UNMAPPED' not in ids.values(), 'unassigned release path'
assert set(overrides)<=set(ids), 'an explicit boundary owner path left the census'
print('total',len(ids),'unique',len(set(ids)),'old survivors',len(set(ids)&set(old)),'retired',set(old)-set(ids),'new',set(ids)-set(old))
for k,n in sorted(collections.Counter(ids.values()).items()):print(k,n)
for p,k in ids.items():
 if k in ('CORE','CORE_TEST','UNMAPPED'):print(k,p)
with open(pathlib.Path(__file__).with_name('assignments.csv'),'w') as f:
 w=csv.writer(f,lineterminator='\n');w.writerow(['path','release_lines','package','frozen_owner','frozen_disposition','confidence'])
 for r in cur:
  p=r['path'];o=old.get(p,{});w.writerow([p,r['lines'],ids[p],o.get('proposed_owner','NEW'),o.get('disposition','split'),o.get('confidence','provisional')])
