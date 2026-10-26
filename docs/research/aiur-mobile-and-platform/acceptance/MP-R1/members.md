# MP-R1 member receipts

Observed 2026-10-26 against `main` at
`889212aa39a2fb992da7942c6e4236f7b70be376`.
The first table uses the original 69 member IDs in #3342, matched exactly to issue titles.
GitHub closure events identify the closing PR, and each of the 67 merge SHAs
passes `git merge-base --is-ancestor <sha> <tested-main>`.
Closed issue labels alone were not treated as merge evidence.

## Accepted dispositions

- **#3288 / C6-T04:** closed `NOT_PLANNED`; DESIGN-R1 S4 keeps the lean
  run shape internal. No operator flag was shipped or tested. See its
  [disposition](https://github.com/aiur-team/aiur/issues/3288#issuecomment-6182736126)
  in the Agent Workpad.
- **#3339 / C11-T02:** completed as a recurring research runbook, published at
  `4bb0cf228b97389172685bbbc955d83ad021e6a9`,
  [accepted by the Executor](https://github.com/aiur-team/aiur/issues/3339#issuecomment-6172612118).
  It had no main PR. The final main refresh is #3340 / #6312 below.

Thus the literal “every member merged” criterion has two explicit dispositions;
this report does not turn those dispositions into merge claims.

## Closing PRs

Every SHA below is an ancestor of the tested main.

| Member | Issue | Closing PR | Merge SHA |
| --- | --- | --- | --- |
| MP-R1-C1-T01 | #3256 | [#3515](https://github.com/aiur-team/aiur/pull/3515) | `28a3251fe4e790f3bbcb13a29f65eb4262dab0bc` |
| MP-R1-C1-T02 | #3257 | [#3530](https://github.com/aiur-team/aiur/pull/3530) | `7938d2d5ff2df88d0f4b226aa2510ab9aab1d171` |
| MP-R1-C1-T03 | #3258 | [#3578](https://github.com/aiur-team/aiur/pull/3578) | `757434b4fce4b93b4fe72cd6226fb92c23791cb9` |
| MP-R1-C1-T04 | #3265 | [#3529](https://github.com/aiur-team/aiur/pull/3529) | `5ba2fc1ceb068113ebb64de8f20ab83100e04908` |
| MP-R1-C1-T05 | #3300 | [#3689](https://github.com/aiur-team/aiur/pull/3689) | `d3db13260c8dfae19eb784883a5851e527593d7b` |
| MP-R1-C1-T06 | #3259 | [#3688](https://github.com/aiur-team/aiur/pull/3688) | `fe613607245a226528853919ebd54aab71830ece` |
| MP-R1-C2-T01 | #3260 | [#3527](https://github.com/aiur-team/aiur/pull/3527) | `6322b166cdacbe88632619e08344128846e4f48e` |
| MP-R1-C2-T02 | #3261 | [#3534](https://github.com/aiur-team/aiur/pull/3534) | `46b5e89c62778a773b58b38883b49181933665cf` |
| MP-R1-C3-T01 | #3262 | [#3618](https://github.com/aiur-team/aiur/pull/3618) | `181eb3d87eee50b9fb861e86d9276ba930acb5b7` |
| MP-R1-C3-T02 | #3268 | [#3686](https://github.com/aiur-team/aiur/pull/3686) | `e52c4ec807edd81e4a49513a2f0cdcda22d3fe65` |
| MP-R1-C3-T03 | #3266 | [#3684](https://github.com/aiur-team/aiur/pull/3684) | `5787761bf41dd13b047eaf39ce081c505098bbda` |
| MP-R1-C3-T04 | #3263 | [#3734](https://github.com/aiur-team/aiur/pull/3734) | `c1d32d7189870304fb940ae655fa40da73cfda5b` |
| MP-R1-C3-T05 | #3264 | [#3680](https://github.com/aiur-team/aiur/pull/3680) | `083a0c0f04c44cba8afb3a2e3b066d0ef1d4e5b5` |
| MP-R1-C3-T06 | #3267 | [#3732](https://github.com/aiur-team/aiur/pull/3732) | `65b03d62475b4a3569b4f137f156472bf074e778` |
| MP-R1-C3-T07 | #3269 | [#3701](https://github.com/aiur-team/aiur/pull/3701) | `b390d92f632901e5c8820100d2a46d90308699aa` |
| MP-R1-C4-T01 | #3289 | [#3584](https://github.com/aiur-team/aiur/pull/3584) | `4143d319095d35d6929ecc6896c2ba65788f878d` |
| MP-R1-C4-T02 | #3270 | [#3575](https://github.com/aiur-team/aiur/pull/3575) | `4985c8f9bcb81732c773de6c97a96ff9518d4ec3` |
| MP-R1-C4-T03 | #3271 | [#3576](https://github.com/aiur-team/aiur/pull/3576) | `218228b1c77e7b1fbd3103174d747c88ac975b18` |
| MP-R1-C4-T04 | #3272 | [#3706](https://github.com/aiur-team/aiur/pull/3706) | `fac02a997f012579cba18170e34a08e3474c9be4` |
| MP-R1-C4-T05 | #3273 | [#3531](https://github.com/aiur-team/aiur/pull/3531) | `dd7fc3f5769500c39f17531663ed8e9089d09d6f` |
| MP-R1-C5-T01 | #3280 | [#3702](https://github.com/aiur-team/aiur/pull/3702) | `797fb5087fe21f8b93502854eeefc80a42cdfd98` |
| MP-R1-C5-T02 | #3292 | [#3583](https://github.com/aiur-team/aiur/pull/3583) | `80466f370e3bd7d54abc0d7831a962ae1c1b9926` |
| MP-R1-C5-T03 | #3281 | [#3574](https://github.com/aiur-team/aiur/pull/3574) | `2ac4ea24fb639ecfc33a6a4e57f951beedf13d4e` |
| MP-R1-C5-T04 | #3282 | [#6275](https://github.com/aiur-team/aiur/pull/6275) | `f903e71ac82ecfd1fb8993838a6a3246bfa35fe4` |
| MP-R1-C5-T05 | #3283 | [#3989](https://github.com/aiur-team/aiur/pull/3989) | `276ddac93751624365a74163373fca43e47f774b` |
| MP-R1-C5-T06 | #3284 | [#3993](https://github.com/aiur-team/aiur/pull/3993) | `a1a67b9f9a6ba057f67661d82aa8ed3ee714aaca` |
| MP-R1-C6-T01 | #3286 | [#3735](https://github.com/aiur-team/aiur/pull/3735) | `e777b37e011551800b81f84cd489bab5c0174f54` |
| MP-R1-C6-T02 | #3285 | [#3553](https://github.com/aiur-team/aiur/pull/3553) | `d45b3eb07871e2c2cab8e6f550398c2b529039af` |
| MP-R1-C6-T03 | #3287 | [#4025](https://github.com/aiur-team/aiur/pull/4025) | `09d4b950cb11f82538c464e79ac66c20cda46dd4` |
| MP-R1-C6-T04 | #3288 | Disposition below | — |
| MP-R1-C7-T01 | #3290 | [#3690](https://github.com/aiur-team/aiur/pull/3690) | `496dda7dcd3b2d6d1fff9690bf938c7b0301b932` |
| MP-R1-C7-T02 | #3291 | [#3730](https://github.com/aiur-team/aiur/pull/3730) | `20f078ba79b3b68c293af3c6512e8296d2a586af` |
| MP-R1-C7-T03 | #3293 | [#4001](https://github.com/aiur-team/aiur/pull/4001) | `45676e9703717dc925c9020d0bcf86894625e582` |
| MP-R1-C7-T04 | #3298 | [#4414](https://github.com/aiur-team/aiur/pull/4414) | `9abedf8361fbe53f52a9ee2a01c2a8c5bb0b8201` |
| MP-R1-C7-T05 | #3299 | [#5029](https://github.com/aiur-team/aiur/pull/5029) | `0acd841c5062aa71908831b53b52d7c4d0ff35d8` |
| MP-R1-C7-T06 | #3301 | [#4408](https://github.com/aiur-team/aiur/pull/4408) | `5db4d0c2c7d4becbae1e2493ce796a2c780a84f3` |
| MP-R1-C7-T07 | #3309 | [#5024](https://github.com/aiur-team/aiur/pull/5024) | `4d73695dbce8be742b1809bcfc7bb28a2adc9ad9` |
| MP-R1-C7-T08 | #3310 | [#5160](https://github.com/aiur-team/aiur/pull/5160) | `691e676bcef588e93d393d715fa85854172b5ccd` |
| MP-R1-C8-T01 | #3312 | [#3721](https://github.com/aiur-team/aiur/pull/3721) | `71295e0c73ced6ed75cd97b2d9636f33cc12f7b3` |
| MP-R1-C8-T02 | #3313 | [#4018](https://github.com/aiur-team/aiur/pull/4018) | `9487f665cd776183c45ece259d84a8037a8dd49b` |
| MP-R1-C8-T03 | #3314 | [#3727](https://github.com/aiur-team/aiur/pull/3727) | `d7fad40553019032df0a50354e1a9b559dd7540b` |
| MP-R1-C8-T04 | #3315 | [#4003](https://github.com/aiur-team/aiur/pull/4003) | `6f76228935e75cb4acc251be06afce7de69c60f5` |
| MP-R1-C8-T05 | #3316 | [#3726](https://github.com/aiur-team/aiur/pull/3726) | `f73ac56e60267be1bd2c3102cfa5070697bcfd8a` |
| MP-R1-C8-T06 | #3317 | [#3737](https://github.com/aiur-team/aiur/pull/3737) | `9bc040958846b2614d5e6d21bfad8536c00aeeef` |
| MP-R1-C8-T07 | #3318 | [#3729](https://github.com/aiur-team/aiur/pull/3729) | `81f1a92450f43e5e8c8853ecf6ead9a26e898a1b` |
| MP-R1-C8-T08 | #3319 | [#3743](https://github.com/aiur-team/aiur/pull/3743) | `d2a022fadda5b1844b11b114c5abc18863c62ce1` |
| MP-R1-C8-T09 | #3320 | [#4015](https://github.com/aiur-team/aiur/pull/4015) | `3eed1d161d0ca9fcfe95070ac03bae8341992bd1` |
| MP-R1-C9-T01 | #3325 | [#5035](https://github.com/aiur-team/aiur/pull/5035) | `145929316e4a13a7d30afb3814d3c826778f33cd` |
| MP-R1-C9-T02 | #3326 | [#5161](https://github.com/aiur-team/aiur/pull/5161) | `ae846c79ddb81592d99b6ca7ad74c5f497e76fd9` |
| MP-R1-C9-T03 | #3327 | [#5202](https://github.com/aiur-team/aiur/pull/5202) | `437cb5e3182d6fca72e00e993b43dd33142949ad` |
| MP-R1-C9-T04 | #3328 | [#5437](https://github.com/aiur-team/aiur/pull/5437) | `26af25b6ed5b58b272eb14070b492a9ddd3960e7` |
| MP-R1-C9-T05 | #3329 | [#3733](https://github.com/aiur-team/aiur/pull/3733) | `54d40ac90ab61c92ebf42511ea429937c4a7e15f` |
| MP-R1-C9-T06 | #3330 | [#3742](https://github.com/aiur-team/aiur/pull/3742) | `ae1ba07f64dec17eb0fc608adc124569da860048` |
| MP-R1-C9-T07 | #3344 | [#3554](https://github.com/aiur-team/aiur/pull/3554) | `f97b4c5854294e097404f55805d3cacaa18aef5c` |
| MP-R1-C9-T08 | #3331 | [#3739](https://github.com/aiur-team/aiur/pull/3739) | `d30bfc88bb2231c4d4d20cd44b07797c7b6f5a90` |
| MP-R1-C9-T09 | #3332 | [#4422](https://github.com/aiur-team/aiur/pull/4422) | `2c69042f98c90809c2b500780b26f710ce8684d0` |
| MP-R1-C9-T10 | #3333 | [#3744](https://github.com/aiur-team/aiur/pull/3744) | `f46c8bcedf5b84a5f8c4e105be79b4864b3f2163` |
| MP-R1-C9-T11 | #3334 | [#4021](https://github.com/aiur-team/aiur/pull/4021) | `e91b997f6d32d4cb8eaf3c0afc641079c353c3c7` |
| MP-R1-C9-T12 | #3335 | [#4409](https://github.com/aiur-team/aiur/pull/4409) | `74dc7a1b592c732a5057413f1cb3469eaeec5776` |
| MP-R1-C9-T13 | #3336 | [#4460](https://github.com/aiur-team/aiur/pull/4460) | `93eff8275b32006aae40131a9b365839416da1d6` |
| MP-R1-C9-T14 | #3337 | [#5026](https://github.com/aiur-team/aiur/pull/5026) | `c96025161f1688888de4159d8c31fb117a989b6a` |
| MP-R1-C10-T01 | #3321 | [#3557](https://github.com/aiur-team/aiur/pull/3557) | `5febfcbcf7fa8c1c69fe7e2f95346a6a1b52923a` |
| MP-R1-C10-T02 | #3322 | [#4403](https://github.com/aiur-team/aiur/pull/4403) | `1fe9e5cf5b3fd766054f176091c1cf041c06d19c` |
| MP-R1-C10-T03 | #3323 | [#6354](https://github.com/aiur-team/aiur/pull/6354) | `4512dbeda9d543912c10a581d0272ca4f2900819` |
| MP-R1-C10-T04 | #3324 | [#4404](https://github.com/aiur-team/aiur/pull/4404) | `99553f4a92a24e694fd637b6b464bc0bb3f05705` |
| MP-R1-C10-T05 | #3341 | [#6365](https://github.com/aiur-team/aiur/pull/6365) | `889212aa39a2fb992da7942c6e4236f7b70be376` |
| MP-R1-C11-T01 | #3338 | [#3447](https://github.com/aiur-team/aiur/pull/3447) | `3fe8a11daa7991100abfe67c48c25d37c179dd88` |
| MP-R1-C11-T02 | #3339 | Disposition below | — |
| MP-R1-C11-T03 | #3340 | [#6312](https://github.com/aiur-team/aiur/pull/6312) | `190237c877b277ff7e0790ffa2b293a57d02c0ac` |

## GHA extension of root #3252

The original 69-member population above omitted the six later-added GHA tasks.
The complete reviewed population is **75 tasks: 72 merged, two accepted
administrative dispositions, and one explicitly deferred open task**.

GHA-1 through GHA-5 have these closing PRs; all five merge commits are ancestors
of tested main `889212aa39a2fb992da7942c6e4236f7b70be376`.

| Member | Issue | Closing PR | Merge SHA |
| --- | --- | --- | --- |
| MP-R1-GHA-1 | #3823 | [#5030](https://github.com/aiur-team/aiur/pull/5030) | `1ce902b8977db0620396d57717c08bb610af3be5` |
| MP-R1-GHA-2 | #3824 | [#5482](https://github.com/aiur-team/aiur/pull/5482) | `798b1ea88a050cef569a183375193b0fa1bff1a5` |
| MP-R1-GHA-3 | #3825 | [#6179](https://github.com/aiur-team/aiur/pull/6179) | `a250a316bbb1a43a05569ea4f5793acf74afa08c` |
| MP-R1-GHA-4 | #3826 | [#6241](https://github.com/aiur-team/aiur/pull/6241) | `69d1f79d5fbd9e0523ea5c2bc374749e4880de74` |
| MP-R1-GHA-5 | #3827 | [#6340](https://github.com/aiur-team/aiur/pull/6340) | `1708a001f4d31b373a8737bf837bcf297b41f2cb` |

**MP-R1-GHA-6 / #3828 is OPEN and deferred, not complete.** It owns the physical
package promotion record and its five-condition go/no-go decision.

The logical component, injectable settings, dependency ports, facade and
standalone wrapper are the merged GHA-1..5 work above.

Physical promotion is conditional under
[migration plan §5](../../bucket-1-refactor/MP-R1/migration-plan.md#5-promotion-test-when-a-logical-component-becomes-a-physical-package).
This capstone accepts the current logical form without claiming a physical
package or promotion verdict.

No criterion evaluation or follow-up required by #3828 is claimed delivered.
#3828 remains its owning open task.

[DF-016](../../../../build-order/deferred-findings.md#df-016--mp-r1-gha-6-physical-promotion-record-remains-open)
records why this capstone defers it rather than hiding it or blocking logical QA.

## Receipt verification output

Command: `git merge-base --is-ancestor <merge-sha> 889212aa39a2fb992da7942c6e4236f7b70be376`,
for every SHA in the two tables above.

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:40:22.218883Z
UTC end: 2026-10-26T11:40:23.160879Z
72 merge commits checked; 72 ancestor checks exited 0.
```
