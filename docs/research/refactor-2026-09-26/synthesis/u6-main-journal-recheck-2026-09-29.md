# U6 decision journal recheck at merged main

The [candidate failure matrix](u6-decision-journal-outcome-matrix-2026-09-29.md) was rechecked against merged main `17f82aae243cb1428e3b56b468ef9ed79ecb51e9`. The three production blobs and their two relevant test blobs are byte-identical to candidate `0299daca28383a336682374e19e90d6434aa4e1a`:

| Path | Blob on both commits |
| --- | --- |
| `src/lib/aiur/decision_log.ex` | `6ade3ecfafded0de11ebc2caabb1559be3e71ca8` |
| `src/lib/aiur/decision_store.ex` | `fe3d308b30839fb64d51ac6c16dba17e3de786b7` |
| `src/lib/aiur/decision_projection.ex` | `19e040f0e5e45e0dc2b8689074fee786b7853121` |
| `src/test/aiur/decision_log_test.exs` | `763d45b21c764907fb6fb0602523aadfd060386a` |
| `src/test/aiur/decision_store_test.exs` | `b00cd0acf3d92c5d73296cac968d519d6d0cb8ff` |

The matrix's static behavior claims therefore still apply. The uncertain complete write after a sync failure, accepted journal append with failed projection, and notification/replay policy remain **unresolved contracts**. No fault was injected and no runtime frequency or saving is claimed. Keep U6 at `requirements-only` until an injected failure test establishes whether a retry can duplicate a transition or side effect, and until an accepted event's degraded projection state is visible to each reader.
