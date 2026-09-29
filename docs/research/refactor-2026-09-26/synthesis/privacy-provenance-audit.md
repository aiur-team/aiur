# Contextual privacy and provenance audit

This branch-tip review applies the public-research rule: private sources may
contribute aggregate counts and categories marked private, but no private
configuration value, ticket text, identifier, path, product detail or quote.
It supplements the lexical checker and the prior
[privacy review](privacy-review.md); it is not a history rewrite.

## Scope and method

At the start of this pass, the research tree had 275 tracked artifacts. The
lexical scan covered the whole tree. A contextual screen located 37 files with explicit private-source
markers or aliases and examined their surrounding source claims, including
generated duplicates. The higher-risk families were reviewed by field or
record: all five raw feature inventories (216 feature IDs), all 91 skeptical
challenge records, the 32 raw review units, verdicts for all 60 claims, the
six historical source reports, and private rows in the eight census/gap CSVs.
The existing 121-private-record exact-title/body-window comparison remains
the earlier audit's bounded check; it was not rerun or expanded to paraphrase
detection here.

| Source family | Provenance check and result |
| --- | --- |
| Raw code review | Findings cite frozen public `3339b887` source paths/hashes and preserve source IDs through `review/findings.json`. Private-repo language in the inspected raw units describes generic repo-state tests or a confidentiality rule, not private fixture text. |
| Feature usage and challenges | Public source/boot/transcript quotations near private aggregate counts were traced by their stated Aiur or other public source. Private config use remains counts or commented-template categories. Two notes had stated a private tracker value and were corrected below. |
| Claim verdicts and six source reports | Private-source mentions were checked as aggregate counts/categories; recovered journal hashes predate documented redactions. The reports' selected quotations identify public aiur/khala/archon sources. Unpublished journals and private acceptance records were not copied into this branch. |
| CSV measurements | Private repository aliases remain, while sensitive run IDs, chronology, ticket IDs and issue first/last cells are blank or `withheld`. Private gap rows retain duration/category and `private — omitted` evidence. The prior 76-cell redaction record remains the audit trail. |
| Generated synthesis | `features/features.json` was regenerated after the raw and challenge corrections. Its private-source passages duplicate the checked inputs; its LOC ledger contains frozen public source paths and hashes only. |

## Corrections in this pass

1. `features/raw/ui.json`: two usage rows embedded a private transcript
   directory inside a glob. They now report five public segment counts and
   one private aggregate count without a private path. The coverage note and
   another usage row now say only that two private configs were included,
   rather than placing placeholders in a config-path list.
2. `features/challenges/done.json`: `config-10` and `integrations-03` no longer
   state the private configs' tracker value. The public-config evidence and
   aggregate absence of active Linear configuration remain.
3. `gaps/gap-analysis.md`: the private category-e row now contains only its
   category and duration; a host-crash narrative tied to that private row was
   removed. Public host interruption evidence remains separately cited.
4. `features/features.json` was regenerated from the corrected raw inventory
   and challenge records. No feature ID, recommendation, use label or numeric
   estimate changed. `tooling/privacy_check.py` now fails if a private-repo
   placeholder is embedded in a path scaffold.

The automated privacy scan and a second contextual marker sweep found no
remaining known private value, private path, ticket quotation or credential in
the current tree. This is a review of *published* evidence: raw local session
journals, private configuration files, private tracker records and local
acceptance observations were intentionally not imported for this pass. Their
absence limits independent reproduction of some aggregate claims. Earlier
public commits still contain text later corrected at the branch tip, and
future research artifacts require fresh review before publication.
