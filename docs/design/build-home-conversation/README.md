# Conversation read seam captures

Automated browser fixtures at 1440 × 900, America/Los_Angeles. Capture with:

```sh
env -C src/browser AIUR_BROWSER_KEEP_ARTIFACTS=1 node scripts/run-browser-tests.mjs tests/build-home-conversation.browser.spec.mjs --fully-parallel --workers=3 --grep 'all six|state cues|older loading'
```

| Image | Case |
| --- | --- |
| `conversation-not-retained.png` | S-6 fallback when no doc body is registered |
| `conversation-doc-cue.png` | S-6 note passed to a registered fixture doc body |
| `conversation-loading-earlier.png` | S-15 pending older page |
| `conversation-stale-age.png` | Stale footer with the rendered observation age |
| `conversation-unavailable.png` | Unavailable conversation |
| `conversation-restart-unknown.png` | Unknown live state after a restart |
| `conversation-unknown-time.png` | Unknown entry timestamps |
| `conversation-unknown-model.png` | S-13 letter-circle model fallback |

The doc-cue fixture checks the registration contract; C11-T02 owns the doc body.
