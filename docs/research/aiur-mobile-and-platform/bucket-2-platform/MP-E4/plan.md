# MP-E4 implementation evidence

## 10. Offline workspace replay (RQ-E4-4)

The implementation checkout did not contain the original MP-E4 plan. This
section records the C8-T01 fixture results; the ticket contracts remain in
`tickets/`.

| Backend | Workspace replay | Current-launch IssueLog fallback |
| --- | --- | --- |
| Codex | Completed notification records retain full bodies and item IDs. | When no extractable workspace record remains. |
| Claude | `item/created` notifications replay through its map-access extractor. | When no extractable workspace record remains. |
| Claude REPL | Stored `transcript_event` envelopes replay directly. | When no extractable workspace record remains. |
| Muse | JSON decoding changes the top-level atom keys required by its extractor. | Used for these stored records. |
| Kimi, DeepSeek, OpenRouter | JSON decoding changes the atom keys and event tags required by the shared extractor. | Used for these stored records. |

Evidence: `src/test/aiur/conversation/importer_test.exs` serializes each fixture
before replay, including the atom-only extractor cases. No source files are
rewritten. Missing sources leave the `pre_journal` gap; imported history never
claims completeness. IssueLog fallback covers only this launch, with bodies at
the 1,000-character cut marked truncated.
