import csv,collections,pathlib
import argparse, re, subprocess, tempfile, shlex
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
def refresh(sha):
 root = pathlib.Path(subprocess.check_output(['git', '-C', str(base), 'rev-parse', '--show-toplevel'], text=True).strip())
 def git(*args):
  return subprocess.check_output(['git', '-C', str(root), *args])
 sha = git('rev-parse', '--verify', sha + '^{commit}').decode().strip()
 release = {r['path']: r for r in csv.DictReader(open(base/'u8-release-007/assignments.csv'))}
 entries = [r.split(b'\t', 1) for r in git('ls-tree', '-rz', sha).split(b'\0') if r]
 blobs = {}; counts = collections.Counter()
 proc = subprocess.Popen(['git', '-C', str(root), 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
 for info, path in entries:
  mode, kind, oid = info.split(); path = path.decode()
  if mode == b'120000': counts['symlinks'] += 1; continue
  if kind != b'blob': continue
  proc.stdin.write(oid + b'\n'); proc.stdin.flush()
  size = int(proc.stdout.readline().split()[2]); data = proc.stdout.read(size); assert proc.stdout.read(1) == b'\n'
  counts['blobs'] += 1
  try:
   if b'\0' in data: raise UnicodeError
   text = data.decode('utf-8')
  except UnicodeError: counts['binary'] += 1; continue
  counts['text'] += 1
  lines = data.count(b'\n') + int(bool(data) and not data.endswith(b'\n'))
  blobs[path] = (lines, text)
 proc.stdin.close(); assert proc.wait() == 0
 census = {p: n for p, (n, _) in blobs.items() if n > 500}
 fields = list(next(iter(release.values()))) + ['current_lines', 'delta_since_release', 'callers_checked', 'behavior_test', 'next_action']
 rows = []
 snapshot = tempfile.TemporaryDirectory(prefix='u0-ledger-')
 for path, (_, content) in blobs.items():
  target = pathlib.Path(snapshot.name) / path; target.parent.mkdir(parents=True, exist_ok=True); target.write_text(content)
 for path, n in sorted(census.items()):
  previous = release.get(path); owner = previous['package'] if previous else assign(path, 'NEW')
  # Accounts owns harness/account identity, alongside provider-account telemetry.
  if path in ['src/lib/aiur/accounts.ex', 'src/test/aiur/accounts_test.exs']: owner = 'TELEMETRY'
  if path == 'src/lib/aiur/model_availability.ex': owner = 'AGENT_CORE'
  if path == 'src/test/aiur/orchestrator/global_pause_test.exs': owner = 'LIFECYCLE_STATUS'
  if path.startswith('src/test/fixtures/build_home/design-source/'): owner = 'BROWSER'
  if path.startswith('docs/aiur-style/') or path.startswith('packages/aiur-style/'): owner = 'BROWSER'
  assert owner in {r['package'] for r in release.values()}, (path, owner)
  row = dict(previous) if previous else dict(zip(fields[:6], [path, '', owner, 'NEW', 'split', 'provisional']))
  row['package'] = owner
  row.update(current_lines=n, delta_since_release=n-int(previous['release_lines']) if previous else 'new')
  text = blobs[path][1]
  modules = re.findall(r'^defmodule\s+([\w.]+)', text, re.M)
  if modules:
   # Search pinned files through rg; a hit counts a referencing line, excluding this file.
   result = subprocess.run(['rg', '--hidden', '--no-ignore', '-n', '-F', '--glob', '!' + path, *sum((['-e', m] for m in modules), []), '.'], cwd=snapshot.name, text=True, capture_output=True)
   assert result.returncode in (0, 1), result.stderr
   hits = [':'.join(line.removeprefix('./').split(':', 2)[:2]) for line in result.stdout.splitlines()]
   row['callers_checked'] = str(len(hits)) + ' rg external qualified-module lines; modules=' + '|'.join(modules)
   if path.startswith('src/test/'):
    tests = [path]
   else:
    sibling = path.replace('src/lib/', 'src/test/', 1).removesuffix('.ex') + '_test.exs'
    tests = sorted({h.rsplit(':', 1)[0] for h in hits if h.startswith('src/test/')})
    tests = [sibling] if sibling in blobs else tests[:3]
   row['behavior_test'] = '; '.join(tests) or 'none found: add seam regression before split'
  else:
   code = pathlib.Path(path).suffix in {'.py', '.js', '.mjs', '.ts', '.css', '.sh'} or path in {'scripts/aiurdev'}
   if code:
    result = subprocess.run(['rg', '--hidden', '--no-ignore', '-n', '-F', '--glob', '!' + path, '-e', pathlib.Path(path).name, '.'], cwd=snapshot.name, text=True, capture_output=True)
    assert result.returncode in (0, 1), result.stderr
    hits = [line.removeprefix('./').split(':', 1)[0] for line in result.stdout.splitlines()]
    row['callers_checked'] = str(len(hits)) + ' rg external filename-reference lines; dynamic imports require seam review'
    row['behavior_test'] = '; '.join(sorted({p for p in hits if '/test' in p})) or 'none found: package validation in proposal.md; add seam regression before split'
   else:
    row['callers_checked'] = 'n/a: document/generated/vendor data; path consumers require seam review'
    row['behavior_test'] = 'n/a: no executable module; package validation in proposal.md'
  action = old.get(path, {}).get('action', 'Split by semantic responsibility; preserve entry points and focused behavior coverage.')
  if pathlib.Path(path).name in {'package-lock.json', 'bun.lock'}:
   folder = str(pathlib.Path(path).parent)
   command = 'bun install --lockfile-only' if pathlib.Path(path).name.startswith('bun') else 'npm install --package-lock-only'
   action = 'regenerate: (cd ' + folder + ' && ' + command + '); verify pinned toolchain and dependency parity'
  if row['frozen_disposition'] == 'regenerate' and pathlib.Path(path).name not in {'package-lock.json', 'bun.lock'}:
   action = 'regenerate: approve bounded generator first; reproduce baseline: git show ' + shlex.quote(sha + ':' + path) + '; ' + action
  if row['frozen_disposition'] == 'remove':
   action += ' Candidate only: git rm -- ' + shlex.quote(path) + '; first preserve readers; reproduce baseline: git show ' + shlex.quote(sha + ':' + path)
  if path.startswith('src/test/fixtures/build_home/design-source/'):
   action = 'remove: only after design-authority approval and browser parity; reproduce original via git show ' + shlex.quote(sha + ':' + path) + '; re-export: npm --prefix src/browser run fixtures:build-home'
   row['behavior_test'] = 'src/browser/tests/build-home-assets.browser.spec.mjs; npm --prefix src/browser run check:build-home-fixtures'
  if path == 'packages/aiur-style/package-lock.json': row['behavior_test'] = 'packages/aiur-style/test/dist.test.mjs; npm --prefix packages/aiur-style ci'
  row['next_action'] = action
  rows.append(row)
 snapshot.cleanup()
 output = base / ('u0-owner-ledger-' + sha[:9] + '.csv')
 with output.open('w') as f:
  writer = csv.DictWriter(f, fields, lineterminator='\n'); writer.writeheader(); writer.writerows(rows)
 assert {r['path'] for r in rows} == set(census) and len(rows) == len(census)
 assert all(r['package'] and r['next_action'] for r in rows)
 print('sha', sha, 'counts', dict(counts), 'oversized', len(rows))
 print('new', sorted(set(census)-set(release)))
 print('retired', sorted(set(release)-set(census)))
 print('changed', sum(census[p] != int(release[p]['release_lines']) for p in set(census)&set(release)))
 print('net delta', sum(census[p]-int(release[p]['release_lines']) for p in set(census)&set(release)))
 print('owners', dict(sorted(collections.Counter(r['package'] for r in rows).items())))

parser = argparse.ArgumentParser(description='Build release assignments or refresh the implementation-SHA owner ledger.')
parser.add_argument('--sha', help='Pinned implementation commit; does not overwrite release assignments')
args = parser.parse_args()
if args.sha:
 refresh(args.sha)
 raise SystemExit
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
