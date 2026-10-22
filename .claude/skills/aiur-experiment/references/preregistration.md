# Blind pre-registration

Use the installed `preregistration.v1` contract. Read the spec and pack before
choosing metrics; the primary is the outcome the treatment was designed to
move. One primary is preferable; two require Holm correction at the registered
alpha. Secondaries use Benjamini-Hochberg at q = 0.10. Cost and quality
constraints are guardrails, selected from the pack rather than invented.

Register experiment id, analyst identity, one hypothesis, primary/secondary/
guardrail metric ids and expected directions, alpha (normally 0.05), secondary
correction and q, signed relative MDE and its metric, power target (normally
0.80), planned n per cohort, projected readiness, strata, reasoned exclusions,
stopping rule and frozen baseline snapshot hash. Copy planned n and readiness
from X4's baseline power plan; never estimate them yourself. Define MDE as the
smallest change worth acting on, with units and denominator clear.

Expected direction and pack `better` are distinct: a hypothesized decrease
may be harmful for a higher-is-better metric. State the expectation explicitly.
Choose strata from collected attributes; complexity is the default when
available. Fix exclusion rules before seeing outcomes. The stopping rule is
one confirmatory analysis at planned n, with earlier reports descriptive.
Do not use repeated p-value looks to decide when to stop.

Never read post-period outcomes or previous reports in this mode. The server
owns `post_hoc`, comparing registration time to the first results read;
author-supplied `false` cannot prove blindness. If unblinded, disclose the read
and treat the registration as post-hoc. Later submissions are amendments with
a required reason; retain the original. Amendments after a results read must
remain visible. No retroactive exclusions, hypotheses or metric switches may
be presented as pre-registered.
