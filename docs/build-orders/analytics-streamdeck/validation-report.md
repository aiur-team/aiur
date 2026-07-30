# Validation report — analytics-streamdeck

- `validate_build_order.py build-order.json`: **0 errors, 0 warnings**
  (2026-07-30). Graph mode only; marker-based materialization NOT used — the
  26 GitHub issues predate the pack and their bodies are the worker contracts.
  `github`/`github_root`/`github_reconciliation` are deliberately null; the
  logical→issue mapping is a generated view (README.md) and in each ticket doc.
- Serialization symmetry: AS-105 ⇄ AS-211/AS-212 (dashboard.css clique).
- Capstone AS-217 transitively covers all 26 tickets.
- Requirements REQ-001..REQ-011 bidirectionally traced.
- Design evidence: three research docs copied to evidence/ with SHA-256.
- Adversarial review: research packs were cross-checked against source
  (three-layer debug gate verified in code; HID facts corroborated across
  three libraries + official Elgato docs; security claims verified in source
  with two overclaims corrected — see research docs "verified/could-not-verify"
  sections). Formal ce-doc-review not run (operator prioritized launch);
  recorded here as a known gap.
