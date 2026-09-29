# Feature usage matrix

The five linked tables cover all 216 frozen feature entries. Their observed-use labels come from bounded transcript, config and log samples; `none-found` is not proof of no users. Raw `lib_loc` and `test_loc` footprints overlap across features and must not be summed into a deletion estimate. The challenge column tracks whether a cut/merge/externalize candidate has received a skeptical pass; an unchallenged recommendation is not a decision.

| Surface | Features | Usage table |
| --- | ---: | --- |
| cli | 46 | [cli](matrix/cli.md) |
| config | 39 | [config](matrix/config.md) |
| integrations | 52 | [integrations](matrix/integrations.md) |
| subsystems | 46 | [subsystems](matrix/subsystems.md) |
| ui | 33 | [ui](matrix/ui.md) |

The current matrix is an index. Final keep/simplify/merge/cut/externalize decisions and physical line savings belong in `feature-inventory.md` and `loc-reduction.md` after all challenges are resolved.
