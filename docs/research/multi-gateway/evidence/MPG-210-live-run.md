# MPG-210 live run: registered gateways and remote control between PC and Nook

**Status: NOT RUN.** No block below has evidence yet. The run needs a real PC and Nook daemon, dashboard confirmations by a signed-in human, and `scripts/aiurdev --test`, none of which an agent issue workspace can do (see `AGENTS.md`, Manual testing). The Executor runs the steps from the repo root and pastes redacted output under each id.

Runbook with exact commands and expected outputs: [`docs/research/MPG-210.md`](../../MPG-210.md#runbook).

Redaction: one `sed` filter over the capture, never hand edits. Tokens become `aiur_<redacted>`, tailnet names and IPs become `<nook-host>` / `<pc-host>`, gateway ids keep 6 characters. Before committing, grep this file for `aiur_` and the tailnet domain. The third gateway is a loopback daemon under an isolated `HOME`; it exercises the same receiver code but is not a real peer.

## Preflight

Steps: P1-P5: same build commit on PC and Nook; both daemons up; registry/peer files mode 600; record NOOK_REG_0 and NOOK_AUDIT_0.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## G1 registered vs reachable, accurate last seen

Steps: Nook `aiur gateway invite --grant read,message --ttl 10m`; PC `aiur gateway join <code> --name nook`; `aiur gateway list` online with last seen < 1 min; stop Nook 60 s, `aiur gateway list` offline with a non-zero age, still registered.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## G2 discovery and manual registration

Steps: `aiur gateway discover` before and after join; with tailscale off PATH, registry entries only; `aiur gateway register nook2 --url $NOOK_URL --token-file ...` then `aiur --gateway nook2 status`, then `aiur gateway remove nook2`; Nook registry sha256 unchanged by discover.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## G3 read reaches intended gateway, identity pin checked

Steps: `aiur --gateway nook status` shows Nook's instance_id; `--gateway Nook` same; with a wrong `gateway_id` in PC's entry, exit 77 `gateway identity mismatch for 'nook'`; restore the file.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## G4 authorised remote write enforced and audited by receiver

Steps: Nook `aiur gateway grant pc agents` confirmed in Nook dashboard; PC `aiur --gateway nook pause` / `resume` exit 0; Nook audit lines show outcome ok, category agents, peer and origin_gateway = PC, request_id, actor.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## G5 unauthorised writes refused

Steps: After revoke, PC `pause` exit 77 `category_not_granted: agents`; Executor token `aiur --gateway nook gateway grant pc agents` exit 64; same via direct POST 403 `grants_are_local`; Nook registry hash unchanged.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## G6 remote agents and owners shown; offline not idle

Steps: `aiur gateway status nook` with a running agent; after `aiur stop` on Nook, agents shown with age, connectivity offline, workload not idle; `aiur gateway list --json` carries gateway, connectivity, workload, last_seen_at, age_ms, freshness.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## G7 unreachable gateway fails promptly, nothing queued

Steps: With Nook stopped, `time aiur --gateway nook pause` exits 69 in under 10 s with `could not reach remote instance 'nook'`; after restart Nook is not paused and the audit has no pause line.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## G8 delegated tickets stay owned on GitHub

Steps: Take a ticket on Nook, stop Nook, confirm GitHub ownership still names Nook, `aiur --gateway nook message <id> hi` exits 69. Record PARTIAL (needs MPG-502) if ownership refs are not shipped; never PASS.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## G9 existing --instance scripts and local CLI unchanged

Steps: `--instance nook status` equals `--gateway nook status`; both flags together exit 64 `use one of --gateway or --instance`; local `status`/`agents`/`pause`/`resume` match the P2 capture; a legacy registry entry without `gateway_id` works and prints the id once.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## Bypass POST: message-only token, grant-changing expression

Steps: Nook `aiur token create msg-pc --scope write --peer $PC_ID --categories message`; PC curl POST to `$NOOK_URL/api/v1/control` with the grant expression copied from `src/lib/aiur/gateway/cli.ex`; expect 403 `grants_are_local`, registry hash unchanged, one new denied audit line for PC.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**

## G10 fully trusted peers cannot grant over the network

Steps: Trust full both ways (Decisions confirmed in each dashboard); register `third` at `[read]` from a loopback daemon under an isolated HOME; record NOOK_REG_1 and audit count; POST grant `agents` to `pc` then to `third` with PC's full-trust token; expect two 403, registry byte-for-byte equal to NOOK_REG_1, exactly two new denial audit lines.

- Commands and redacted output: _not run_
- Receiver registry hash before / after: _not run_
- Audit line(s): _not run_
- Result: **NOT RUN**
