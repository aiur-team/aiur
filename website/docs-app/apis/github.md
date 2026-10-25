# GitHub

Aiur reads GitHub to find work, follow each ticket, and return completed changes for review. This API reference is split by topic:

- [Polling, repository setup, and cadence](/apis/github-polling)
- [API budgets and credential pooling](/apis/github-budgets)
- [Per-caller cost accounting](/apis/github-costs)
- [Webhooks and resource reconciliation](/apis/github-webhooks)
- [Credentials, trust, and tunnel security](/apis/github-auth)
- [Shared agent reads](/apis/github-agent-cache)

## Legacy topic links

The original topic fragments remain available below for links that predate this split.

### CI failure evidence

See [CI failure evidence](/apis/ci-failure-evidence).

### Poll cadence

Polling intervals and per-class cadence are documented in [GitHub polling](/apis/github-polling#poll-cadence).

### API budgets

Budget meters, attribution, and pooling are documented in [GitHub API budgets](/apis/github-budgets).

### Reading these numbers without fooling yourself

Interpretation guidance lives in [GitHub API budgets](/apis/github-budgets#reading-these-numbers-without-fooling-yourself).

### Shared agent reads

The cache contract lives in [Shared agent GitHub reads](/apis/github-agent-cache).

### Optional webhook

Webhook setup and delivery state lives in [GitHub webhooks](/apis/github-webhooks#optional-webhook).

### Cloudflare tunnel boundary

Tunnel security lives in [GitHub credentials and security](/apis/github-auth#cloudflare-tunnel-boundary).

### Who Aiur trusts

Trust rules live in [GitHub credentials and security](/apis/github-auth#who-aiur-trusts).

### GitHub App authentication

App setup lives in [GitHub credentials and security](/apis/github-auth#github-app-authentication).

### Changes Aiur makes itself

Write-path details live in [Per-caller costs](/apis/github-costs).

### Experiment window evidence

The experiment-window read census lives in [Per-caller costs](/apis/github-costs#experiment-window-evidence).

### Comments arriving twice

Delivery reconciliation lives in [GitHub webhooks](/apis/github-webhooks#comments-arriving-twice).

### One record for one resource

The shared resource record lives in [GitHub webhooks](/apis/github-webhooks#one-record-for-one-resource).

### What the agent guard governs

The agent credential boundary lives in [GitHub credentials and security](/apis/github-auth#what-the-agent-guard-governs).

### Operator PR merge command

See the [CLI reference](/reference/cli#pr-merge).

### Measured feature epics

Membership accounting lives in [Per-caller costs](/apis/github-costs#measured-feature-epics).

### Repository setup from global defaults

Repository setup guidance lives in [GitHub polling](/apis/github-polling).

### What Aiur polls

The polling inventory lives in [GitHub polling](/apis/github-polling).

### Build Order membership recovery

Membership reconciliation lives in [GitHub polling](/apis/github-polling#build-order-membership-recovery).

#### Set up the App

See [GitHub App authentication](/apis/github-auth#github-app-authentication).

#### Configure the daemon

See [GitHub App authentication](/apis/github-auth#github-app-authentication).

#### Organization repository access during init

See [GitHub App authentication](/apis/github-auth#organization-repository-access-during-init).

#### Token lifecycle

See [GitHub App authentication](/apis/github-auth#token-lifecycle).

#### Identity under App auth

See [GitHub App authentication](/apis/github-auth#identity-under-app-auth).

#### What a validator may answer

See [GitHub polling](/apis/github-polling#what-a-validator-may-answer).

#### Where the budget went

See [GitHub API budgets](/apis/github-budgets#where-the-budget-went).

#### Credential pooling

See [GitHub API budgets](/apis/github-budgets#credential-pooling).

#### What pooling is worth

See [GitHub API budgets](/apis/github-budgets#what-pooling-is-worth).

#### Human-review base checks

See [GitHub credentials and security](/apis/github-auth#human-review-base-checks).

##### Writes stay on their own identity

See [GitHub API budgets](/apis/github-budgets#credential-pooling).

## Experiment analyst tickets

See [Per-caller costs](/apis/github-costs#experiment-analyst-tickets) for issue creation, nonce reconciliation and cached ticket-state observations.
