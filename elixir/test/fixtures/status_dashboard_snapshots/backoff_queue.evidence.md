```text
╭─ SYMPHONY STATUS
│ Agents: codex (1/10)                                   │ Project: project
│ Runtime: 65m 25s                                       │ Next refresh: n/a
├─ Running
│
│   ID     TAG      STATE      ISSUE                  AGE / TURN  
│   ─────────────────────────────────────────────────────────────
│   MT-638 todo     working    Sample issue title     20m 25s / 7 
│
├─ Backoff queue
│
│  ↻ MT-450 attempt=4 in 1.250s error=rate limit exhausted
│  ↻ MT-451 attempt=2 in 3.900s error=retrying after API timeout with jitter
│  ↻ MT-452 attempt=6 in 8.100s error=worker crashed restarting cleanly
│  ↻ MT-453 attempt=1 in 11.000s error=fourth queued retry should also render after removing the top-three limit
╰─
```
