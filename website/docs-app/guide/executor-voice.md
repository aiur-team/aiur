# Executor voice

## Open the prototype

From the Build home page (`/`), open **Settings → Talk to Executor** (`/voice`).
The prototype remains available for Kevin’s acceptance, including both providers,
minute meters, session comparison, ratings and delivery receipts.

Select a worker on that page to open its conversation drawer. Its **Dictate**
and **Converse** controls, listener modes and message delivery remain available
when supported and writable. Close the drawer to return to the Executor controls.

## Composer voice

The shared Executor composer from #5723 replaces Executor dictation only. It
does not replace the prototype’s provider comparison or delivery receipts; the
Executor view and send adapter integration is still pending. Converse surface
availability is separate from the retained prototype.

## Voice prototype

On `/voice`, choose **ElevenLabs** or **OpenAI**, enter its model,
and press **Talk to Executor** to start a continuous spoken session. Change the
provider between sessions without editing config or restarting.

Both credentials and the ElevenLabs Agent id must be configured for a two-provider comparison. The voice control
always targets the Executor, regardless of the worker shown in the drawer.

The page shows each provider's cumulative used or reserved minutes. Comparison
limits are 45 minutes each for OpenAI and ElevenLabs on this runtime, separate
from the existing shared daily cap. Starts at the comparison cap are refused;
remaining minutes also shorten the session's automatic stop.

A reservation is
written before connecting. Failed starts and interrupted sessions without a saved
end line charge the whole reservation, including after a daemon restart.

Expand **Compare providers and record Kevin’s rating** for side-by-side session
lines: model, first audio, duration, budget cost estimate, rating (1–5) and note.

First audio measures server session startup to first received agent audio, before
browser playback; sessions with no audio show unavailable.

Ratings and redacted notes survive reloads. The private `comparison.json` sits beside the transcripts;
no audio is stored. Stop the current session before choosing another provider.

The estimates allocate USD 8 / 45 OpenAI minutes and USD 8 / 45 ElevenLabs
minutes; these are evaluation budget rates, not vendor tariffs or invoice limits.
The ledger starts at deployment and excludes earlier provider/account usage.

Before each attended comparison, reconcile actual prior spend and account usage
against the USD 25 approval on #4084; record each delta there. End both sessions
after evaluation and disable the demo. Kevin's choice (or “not yet”) belongs on
#4083 before Stream Deck voice work is filed.

The control shows not configured, connecting, live, ended or failed. Press
**End Executor conversation** to send the transcript and categorized summary.
Each item keeps its sent event id and timestamp after the session ends.

Receipts say **sent, not received** until the Executor acknowledges the
matching wake. **Received** confirms acknowledgment, not approval or execution.
A missing acknowledgment stays visible; re-rendering the page or starting
another session preserves earlier receipts. A failed handoff shows an error.

The summary separates decisions, open questions and ideas. If the assistant did
not record one before ending, the page says **unstructured**; the transcript
is still sent without inventing decisions.

Use HTTPS or localhost for microphone access. See
[Executor voice setup](/reference/configuration-voice#executor-voice-prototype-setup)
for provider configuration, credentials and ElevenLabs client-tool setup.
