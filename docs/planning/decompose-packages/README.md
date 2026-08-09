# Decompose packages

Planning only. Nothing here is scheduled, and nothing here is implemented.

## The gate

**No work in this directory starts until the current features and pages reach
full parity and stability.**

That is a hard gate, not a preference. It exists because this repository has
already paid for the alternative: work started on top of an unstable base
produces PRs that fail on defects they did not cause, and reviewers cannot tell
a real regression from noise. On 2026-08-08 three unrelated pull requests failed
three different tests, and two of the three were documentation-only.

### What "parity and stability" means, concretely

Parity — the Stream Deck build order (#1567) is complete:

- the `/streamdeck` page matches the committed design in
  `docs/design/streamdeck/`
- the downloadable package renders the same surface as the web emulator
- keys, progress, logs and provider meters read real fleet state

Stability — the four operator pages work and the base branch is trustworthy:

- Units, Commands, Build Order and Analytics each render correct data, and a
  resolution failure is visually distinct from a legitimate empty (#1616)
- `develop` is green, and the known flake mechanisms are closed: #1602
  (`CycleFetchCache` ETS race) and #1620 (`assert_receive` under contention).
  #1563 closed on 2026-08-08.
- the control surface answers under load — `aiur status` never returns empty
  output with no error (#1610, #1231, #1058)

Check that list before starting anything here. If any item is open, this
directory stays closed.

## What this is for

A place to record decisions about decomposing the packages, made with the
operator, before any code moves. One document per decision.

Nothing has been decided yet. The next step is discussion, not design.

## Rules for documents in this directory

- Record **decisions and their reasons**, not implementation.
- State what was rejected and why. A decision without its discarded
  alternatives cannot be revisited honestly six weeks later.
- Cite real file paths and line numbers when describing current structure. A
  claim about how the code is arranged today must be checkable.
- Do not file tickets from these documents until the gate above is met.
