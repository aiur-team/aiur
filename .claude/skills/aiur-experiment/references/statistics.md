# Interpret the engine

All p-values, corrections, intervals, effects, power, MDE and samples-needed
come from X4 output pinned by its snapshot hash. Do not compute them by hand
or invent a missing statistic. Preserve unavailable values with a reason.

Evidence ladder, weakest to strongest:
`not-enough-data` < `underpowered` < `inconclusive` <
`no-effect-detected` < `significant`. `confounded` is a modifier; direction
is separate (`as-expected`, `opposite`, `none`). Copy `engine_label`; the final
label may only match it or be weaker with `label_reason`. Overall labels
come from primary rows. Sensitivity and exploratory metrics never upgrade them.

Report n for each cohort/stratum, median and IQR where the engine supplies
them, effect with 95% CI first, then raw/adjusted p and correction family.
A label alone is not a result. For skewed flow times use the engine's medians,
Mann-Whitney U and bootstrap CIs rather than substitute means. Other packs
use their engine-defined estimator, unit and method.

Primaries use Holm at registered alpha; secondaries use Benjamini-Hochberg
at q = 0.10. Other metrics are exploratory and cannot support the
recommendation. Name any deviation from registration and the engine's method;
do not post-hoc switch families to obtain significance.

For `no-effect-detected`, say “consistent with no effect larger than X” only
when supported by the engine's interval/MDE, and give X with units. Never say
“proved” or equate a large p-value with equivalence. For `underpowered`, quote
`n_needed_per_cohort` and projected readiness, preserving unavailable values.
Explain power at the registered MDE as the engine's estimated detection
probability for that size; MDE at current n is the smallest effect the current
sample can detect at the target power. Neither predicts the observed p-value.

Below planned n, report interim/descriptive status and do not recommend from
nominal significance. One planned confirmatory look avoids repeated-testing
false positives. Report balance, SRM and missingness before interpreting effects.
A significant harmful effect can justify reverting; significance is not benefit.

Additional analyst-computed checks belong only in marked `sensitivity[]`
entries with complete script text in `reproduce`, never as replacement engine
statistics or a means of changing labels upward.
