# MP-E6 tickets after the refactor refresh

Target: `4fbe109541ba1e279d3eb315d8455c4d139c92ba`. Existing gates remain; named REFRESH items are owned source audits in the final refresh report. Historical designs and contracts retain their pinned research versions.

| Ticket | Current pack status | Gates |
| --- | --- | --- |
| [MP-E6-C1-T01](MP-E6-C1-T01.md) | blocked | [E6-OQ9, E6-OQ13, DESIGN-E6] |
| [MP-E6-C10-T01](MP-E6-C10-T01.md) | blocked | ["DESIGN-E6 (waived for this ticket: agent protocol, no UI)", MP-R2-C5-T01, REFRESH-MP-E6-C10-T01-4fbe1095] |
| [MP-E6-C10-T02](MP-E6-C10-T02.md) | ready | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C10-T01, MP-E6-C4-T03, MP-E6-C4-T05, MP-E6-C11-T08] |
| [MP-E6-C10-T03](MP-E6-C10-T03.md) | ready | [] |
| [MP-E6-C10-T04](MP-E6-C10-T04.md) | blocked | [DESIGN-E6, E6-OQ12, MP-E6-C10-T01, MP-E6-C10-T02, MP-E6-C5-T03, MP-E6-C5-T06] |
| [MP-E6-C10-T05](MP-E6-C10-T05.md) | blocked | [MP-E6-C5-T04, MP-E6-C10-T03] |
| [MP-E6-C11-T01](MP-E6-C11-T01.md) | ready | ["DESIGN-E6 (waived for this ticket: backend, no UI)"] |
| [MP-E6-C11-T02](MP-E6-C11-T02.md) | ready | ["DESIGN-E6 (waived for this ticket: no aiur UI)", MP-E6-C11-T01, MP-E6-C4-T01] |
| [MP-E6-C11-T03](MP-E6-C11-T03.md) | ready | ["DESIGN-E6 (waived: example page is not aiur UI)", MP-E6-C11-T02, MP-E6-C5-T03, MP-E6-C11-T08] |
| [MP-E6-C11-T04](MP-E6-C11-T04.md) | ready | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C11-T01, MP-E6-C3-T01, MP-R5-C1-T01, MP-R1-C1-T01] |
| [MP-E6-C11-T05](MP-E6-C11-T05.md) | blocked | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C10-T03 (spike verdict per mode), MP-R7-C2-T02 (optional callbacks reserved), "MP-R7 contract request R-6", E6-OQ21] |
| [MP-E6-C11-T06](MP-E6-C11-T06.md) | superseded | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C1-T01 (which provider won), MP-E6-C2-T03, E6-OQ20] |
| [MP-E6-C11-T07](MP-E6-C11-T07.md) | ready | ["DESIGN-E6 (waived for this ticket: package docs, not aiur UI)", MP-E6-C11-T03, MP-E6-C11-T04, MP-E6-C3-T03, "E6-OQ16/OQ18 only for the publish step"] |
| [MP-E6-C11-T08](MP-E6-C11-T08.md) | blocked | [MP-E6-C11-T01] |
| [MP-E6-C12-T01](MP-E6-C12-T01.md) | ready | [] |
| [MP-E6-C12-T02](MP-E6-C12-T02.md) | blocked | [MP-E6-C13-T07, MP-E6-C12-T01, MP-E6-C11-T05, "MP-E6-C10-T03 (spike adds an Executor-shaped mid-tool-call parent)"] |
| [MP-E6-C12-T03](MP-E6-C12-T03.md) | blocked | [MP-E6-C12-T02, MP-E6-C4-T06, MP-E6-C5-T03, MP-E6-C5-T04, MP-E6-C10-T05] |
| [MP-E6-C12-T04](MP-E6-C12-T04.md) | blocked | [MP-E6-C12-T03, "MP-E6-C7-T02 (Converse panel, Executor entry)"] |
| [MP-E6-C13-T01](MP-E6-C13-T01.md) | blocked | [MP-E6-C11-T02, MP-E6-C11-T03] |
| [MP-E6-C13-T02](MP-E6-C13-T02.md) | blocked | [MP-E6-C14-T01, MP-E6-C13-T01] |
| [MP-E6-C13-T03](MP-E6-C13-T03.md) | blocked | [MP-E6-C13-T01] |
| [MP-E6-C13-T04](MP-E6-C13-T04.md) | blocked | [MP-E6-C11-T02, MP-E6-C13-T05] |
| [MP-E6-C13-T05](MP-E6-C13-T05.md) | blocked | [MP-E6-C2-T01, MP-E6-C11-T02] |
| [MP-E6-C13-T06](MP-E6-C13-T06.md) | blocked | [MP-E6-C11-T03, MP-E6-C13-T01] |
| [MP-E6-C13-T07](MP-E6-C13-T07.md) | blocked | [MP-E6-C11-T01, MP-E6-C10-T03] |
| [MP-E6-C13-T08](MP-E6-C13-T08.md) | blocked | [MP-E6-C13-T01, MP-E6-C13-T02, MP-E6-C13-T03, MP-E6-C13-T06, MP-E6-C13-T07] |
| [MP-E6-C13-T09](MP-E6-C13-T09.md) | blocked | [MP-E6-C13-T04, MP-E6-C13-T08, MP-E6-C14-T04, MP-E6-C14-T02] |
| [MP-E6-C14-T01](MP-E6-C14-T01.md) | blocked | [MP-E6-C2-T01] |
| [MP-E6-C14-T02](MP-E6-C14-T02.md) | blocked | [MP-E6-C2-T01, MP-E6-C14-T01, MP-E6-C13-T05] |
| [MP-E6-C14-T03](MP-E6-C14-T03.md) | blocked | [MP-E6-C2-T01, MP-E6-C14-T01, MP-E6-C13-T05] |
| [MP-E6-C14-T04](MP-E6-C14-T04.md) | blocked | [MP-E6-C2-T01, MP-E6-C14-T01, MP-E6-C13-T05] |
| [MP-E6-C14-T05](MP-E6-C14-T05.md) | blocked | [MP-E6-C14-T04] |
| [MP-E6-C14-T06](MP-E6-C14-T06.md) | blocked | [MP-E6-C3-T01, MP-E6-C14-T01, MP-E6-C11-T04] |
| [MP-E6-C14-T07](MP-E6-C14-T07.md) | blocked | [MP-E6-C14-T01, MP-E6-C13-T07, MP-E6-C11-T02, MP-E6-C13-T05, MP-E6-C13-T02] |
| [MP-E6-C2-T01](MP-E6-C2-T01.md) | ready | ["DESIGN-E6 (waived for this ticket: backend, DESIGN-E6 header)", MP-E6-C11-T01] |
| [MP-E6-C2-T02](MP-E6-C2-T02.md) | blocked | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C2-T01, MP-E6-C11-T01, REFRESH-MP-E6-C2-T02-4fbe1095] |
| [MP-E6-C2-T03](MP-E6-C2-T03.md) | blocked | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C1-T01, MP-E6-C2-T02] |
| [MP-E6-C2-T04](MP-E6-C2-T04.md) | ready | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C2-T02, MP-E6-C6-T01] |
| [MP-E6-C3-T01](MP-E6-C3-T01.md) | blocked | [DESIGN-E6, E6-OQ6, E6-OQ7, MP-R5-C2-T01] |
| [MP-E6-C3-T02](MP-E6-C3-T02.md) | blocked | [DESIGN-E6, E6-OQ7, MP-E6-C1-T01, MP-E6-C3-T01, MP-E6-C2-T02] |
| [MP-E6-C3-T03](MP-E6-C3-T03.md) | blocked | ["DESIGN-E6 (waived for this ticket: backend; refusal copy reuses contract §8 code)", MP-E6-C1-T01, MP-E6-C3-T01, MP-E6-C2-T02, MP-E5-C2-T03] |
| [MP-E6-C4-T01](MP-E6-C4-T01.md) | blocked | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C2-T01, MP-E6-C6-T01, MP-E6-C6-T02, MP-E6-C2-T04, REFRESH-MP-E6-C4-T01-4fbe1095] |
| [MP-E6-C4-T02](MP-E6-C4-T02.md) | ready | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C4-T01, MP-E4-C2-T01, MP-E6-C11-T01] |
| [MP-E6-C4-T03](MP-E6-C4-T03.md) | ready | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C4-T01, MP-E6-C6-T01, MP-E6-C11-T08] |
| [MP-E6-C4-T04](MP-E6-C4-T04.md) | blocked | [DESIGN-E6, E6-OQ3, MP-E6-C3-T01] |
| [MP-E6-C4-T05](MP-E6-C4-T05.md) | ready | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C4-T01, MP-E6-C4-T03, MP-R2-C5-T01, MP-R2-C5-T03] |
| [MP-E6-C4-T06](MP-E6-C4-T06.md) | ready | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C4-T02, MP-E6-C4-T03, MP-E3-C2-T01, MP-E3-C4-T05, MP-E5-C5-T02] |
| [MP-E6-C5-T01](MP-E6-C5-T01.md) | ready | ["DESIGN-E6 (waived for this ticket: backend, read-only tools)", MP-E6-C4-T03] |
| [MP-E6-C5-T02](MP-E6-C5-T02.md) | ready | ["DESIGN-E6 (waived for this ticket: backend; confirm UI is C5-T03/C7-T03)", MP-E6-C5-T01, MP-E6-C6-T01] |
| [MP-E6-C5-T03](MP-E6-C5-T03.md) | blocked | [E6-OQ1 (default adopted - on-screen Confirm only), MP-E6-C5-T02] |
| [MP-E6-C5-T04](MP-E6-C5-T04.md) | blocked | [MP-E6-C5-T03] |
| [MP-E6-C5-T05](MP-E6-C5-T05.md) | ready | ["DESIGN-E6 (waived for this ticket: backend; confirm UI is C7-T03)", MP-E6-C5-T02, MP-E6-C4-T05, MP-E2-C3-T02] |
| [MP-E6-C5-T06](MP-E6-C5-T06.md) | blocked | [MP-E6-C5-T03, MP-E6-C11-T04, MP-E7-C3-T03, MP-E7-C3-T04, DESIGN-E6] |
| [MP-E6-C6-T01](MP-E6-C6-T01.md) | ready | ["DESIGN-E6 (waived for this ticket: backend, DESIGN-E6 header)", MP-E6-C11-T01] |
| [MP-E6-C6-T02](MP-E6-C6-T02.md) | ready | ["DESIGN-E6 (waived for this ticket: backend)", MP-E6-C6-T01, MP-E6-C2-T04] |
| [MP-E6-C6-T03](MP-E6-C6-T03.md) | ready | ["DESIGN-E6 (waived for this ticket: DESIGN-E6 lets C6 proceed; output follows existing CLI table/--json conventions)", MP-E6-C6-T02] |
| [MP-E6-C6-T04](MP-E6-C6-T04.md) | blocked | [DESIGN-E6, E6-OQ5, MP-E6-C6-T02, MP-E6-C6-T03] |
| [MP-E6-C7-T01](MP-E6-C7-T01.md) | blocked | [DESIGN-E6, MP-E6-C4-T01, MP-E6-C2-T03, MP-E5-C2-T01] |
| [MP-E6-C7-T02](MP-E6-C7-T02.md) | blocked | [DESIGN-E6, E6-OQ4, E6-OQ8, MP-E6-C7-T01, MP-E5-C1-T02, MP-E5-C3-T02] |
| [MP-E6-C7-T03](MP-E6-C7-T03.md) | blocked | [DESIGN-E6, E6-OQ1, MP-E6-C7-T02, MP-E6-C5-T03, MP-E6-C5-T06, MP-E6-C5-T05] |
| [MP-E6-C7-T04](MP-E6-C7-T04.md) | blocked | [DESIGN-E6, MP-E6-C1-T01, MP-E6-C7-T02] |
| [MP-E6-C8-T01](MP-E6-C8-T01.md) | blocked | [DESIGN-E6, MP-E6-C6-T02, MP-E6-C7-T02] |
| [MP-E6-C8-T02](MP-E6-C8-T02.md) | blocked | [DESIGN-E6, MP-E6-C8-T01, MP-E6-C4-T03, MP-E6-C5-T02] |
| [MP-E6-C8-T03](MP-E6-C8-T03.md) | blocked | [DESIGN-E6, DESIGN-E4, MP-E6-C8-T01, MP-E4-C3-T02, MP-E7-C3-T04] |
| [MP-E6-C9-T01](MP-E6-C9-T01.md) | blocked | [DESIGN-E6, E6-OQ7, MP-E6-C3-T02, MP-E6-C6-T03, MP-E6-C7-T02, MP-E6-C7-T03, MP-E6-C7-T04, MP-E6-C8-T01] |
