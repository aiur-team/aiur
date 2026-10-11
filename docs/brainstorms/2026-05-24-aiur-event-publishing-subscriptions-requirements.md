---
date: 2026-05-24
topic: Aiur — agent event publishing + subscription system (architecture-aware rewrite)
branch: pubsub
issue: https://github.com/aiur-team/aiur/issues/22
status: ready-for-planning
supersedes: 2026-05-18-aiur-event-publishing-subscriptions-brainstorm.md (deleted in repo cleanup)
archived: f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61 (U8-P25-T01)
---

# Aiur — agent event publishing + subscription system

> Historical record. Full text: https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md

## Ticket split (sequenced)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#ticket-split-sequenced)

## What We're Building

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#what-were-building)

## Why This Approach

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#why-this-approach)

## Existing Infrastructure We're Reusing

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#existing-infrastructure-were-reusing)

## Event vs Alert (separate concepts)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#event-vs-alert-separate-concepts)

## Topic Namespace

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#topic-namespace)

### Surfaces

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#surfaces)

### Agent emit allowlist (locked)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#agent-emit-allowlist-locked)

### Event payload contract

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#event-payload-contract)

### Sanitization of GitHub-sourced user content (in scope for v1)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#sanitization-of-github-sourced-user-content-in-scope-for-v1)

## Event Sources

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#event-sources)

### Branch + ticket + PR events: GitHub `/repos/{owner}/{repo}/events` firehose

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#branch--ticket--pr-events-github-reposownerrepoevents-firehose)

### Agent events: `emit_event` and `emit_alert` tools

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#agent-events-emit_event-and-emit_alert-tools)

### Orchestrator lifecycle events

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#orchestrator-lifecycle-events)

### No git hooks in v1

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#no-git-hooks-in-v1)

### Firehose contamination filter

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#firehose-contamination-filter)

### Base-branch resolver

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#base-branch-resolver)

## Subscriptions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#subscriptions)

### Asymmetric auto-subscriptions on `blocked_by`

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#asymmetric-auto-subscriptions-on-blocked_by)

### Universal auto-subscriptions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#universal-auto-subscriptions)

### Manual subscriptions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#manual-subscriptions)

### Subscription persistence

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#subscription-persistence)

### Writer ownership + atomicity

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#writer-ownership--atomicity)

### Cursor advance semantics — at-least-once delivery

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#cursor-advance-semantics--at-least-once-delivery)

### Persistent monotonic event IDs

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#persistent-monotonic-event-ids)

## Topic Dispatch — `Aiur.Events.Exchange` (AMQP topic-exchange semantics)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#topic-dispatch--aiureventsexchange-amqp-topic-exchange-semantics)

### Wildcards (AMQP standard)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#wildcards-amqp-standard)

### Module shape

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#module-shape)

### One matcher, two consumers

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#one-matcher-two-consumers)

### Coexistence with `Aiur.PubSub`

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#coexistence-with-aiurpubsub)

### Persistence interaction

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#persistence-interaction)

## Delivery

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#delivery)

### Single bundled digest at turn boundary

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#single-bundled-digest-at-turn-boundary)

### No interruption mid-turn

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#no-interruption-mid-turn)

### Bootstrap on agent start

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#bootstrap-on-agent-start)

### Mid-turn drain for blocking-critical events (in scope for v1)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#mid-turn-drain-for-blocking-critical-events-in-scope-for-v1)

### Block / unblock cycling allowed (with debounce)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#block--unblock-cycling-allowed-with-debounce)

### Custom event quota

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#custom-event-quota)

## Surfaces (where events appear)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#surfaces-where-events-appear)

### 1. Per-issue log file

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#1-per-issue-log-file)

### 2. opencode chat pane (small SessionWriter addition, no opencode mod)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#2-opencode-chat-pane-small-sessionwriter-addition-no-opencode-mod)

### 3. Agent-list `Latest` column (new)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#3-agent-list-latest-column-new)

### 3b. Open-attentions detail (TUI + dashboard)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#3b-open-attentions-detail-tui--dashboard)

### 4. Dashboard LiveView events panel (new)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#4-dashboard-liveview-events-panel-new)

### `❗` semantics

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#-semantics)

## `alerts.yaml` v2 — keyed by event topic

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#alertsyaml-v2--keyed-by-event-topic)

## Refactor of `Aiur.Alerts`

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#refactor-of-aiuralerts)

## Shared Agent Instructions — additions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#shared-agent-instructions--additions)

## New configuration

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#new-configuration)

## Dashboard scope

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#dashboard-scope)

## Compile-warning cleanup (in scope)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#compile-warning-cleanup-in-scope)

## `.claude/skills/aiur/` skill (new, on-demand reference)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#claudeskillsaiur-skill-new-on-demand-reference)

## Manual Test — 3-ticket end-to-end (primary verification)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#manual-test--3-ticket-end-to-end-primary-verification)

### Setup

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#setup)

### Tickets

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#tickets)

### `aiur --test` reset flag (new — top-level CLI flag with hard safety guards)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#aiur---test-reset-flag-new--top-level-cli-flag-with-hard-safety-guards)

### Success criteria

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#success-criteria)

## Scope Boundaries

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#scope-boundaries)

### In scope (v1)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#in-scope-v1)

### Out of scope (later)

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#out-of-scope-later)

## Caveats to document and watch in manual testing

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#caveats-to-document-and-watch-in-manual-testing)

## Resolved Questions

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#resolved-questions)

## Related

[Section text at f31ca99f1](https://github.com/aiur-team/aiur/blob/f31ca99f1e185f7567f7b6ea4b6fd57a67ee2c61/docs/brainstorms/2026-05-24-aiur-event-publishing-subscriptions-requirements.md#related)

