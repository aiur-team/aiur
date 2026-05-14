```text
╭─ SYMPHONY STATUS
│ ITS: linear | Agent: codex                             │ Rate Limits: gpt-5 | primary 0/20,000 reset 95s | secondary 0/60 reset 45s | credits none
│ Agents: 1/10                                           │ Project: project
│ Throughput: 15 tps                                     │ Next refresh: n/a
│ Runtime: 45m 0s                                        │ 
│ Tokens: in 18,000 | out 2,200 | total 20,200           │ 
├─ Running
│
│   ID     STATE      ISSUE                      AGE / TURN  
│   ────────────────────────────────────────────────────────
│   MT-638 working    Sample issue title         20m 25s / 7 
│
├─ Backoff queue
│
│  ↻ MT-450 attempt=4 in 1.250s error=rate limit exhausted
│  ↻ MT-451 attempt=2 in 3.900s error=retrying after API timeout with jitter
│  ↻ MT-452 attempt=6 in 8.100s error=worker crashed restarting cleanly
│  ↻ MT-453 attempt=1 in 11.000s error=fourth queued retry should also render after removing the top-three limit
╰─
```
