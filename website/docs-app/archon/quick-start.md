# Quick start

Archon turns a document into one self-contained HTML file.

| Where it runs | What you get |
| --- | --- |
| Anywhere | Inlined CSS and JS, theme-aware, with no bundler and no external requests. It opens from `file://`, survives being emailed, and publishes to any static host. |
| Deployed | The same page gains sign-in, comments anchored to text, suggestions and edits, per-document roles, history and presence. |

## Install

Install the builder package with Node.js 18 or later:

```bash
npm install aiur-archon
npx --no archon --help
```

The package has no runtime dependencies. It installs the builder `archon`, the publisher `archon-publish`, the document skeleton and the `archon-doc` skill.

Always run the commands as `npx --no <command>`. `archon` and `archon-publish` are commands inside `aiur-archon`, not package names: a bare `npx archon` looks the name up on the registry, where `archon` is an unrelated package.

## Prerequisites

| Tool | Why you need it |
| --- | --- |
| Node.js 18 or later | Runs the `aiur-archon` builder and publisher. |
| Your material | Notes, a transcript, research files, an HTML artifact or a prototype to turn into a document. |
| A service origin | Only for publishing. The package has no service origin built in, so you name one with `--service`. |

## Start with your agent

Give your agent one line:

```text
Turn my artifact into an Archon doc: https://archon.aiur.team
```

"My artifact" is the material you hand over. Then:

- The agent reads [the instructions for agents](https://archon.aiur.team/AGENTS.md) and [the `archon-doc` skill](https://archon.aiur.team/skills/archon-doc/SKILL.md).
- It installs the package and builds.
- You get back one built HTML file.
- A hosted link is a separate step, and only happens if you ask for one.

To copy the skill into a Claude Code project so it loads automatically:

```bash
mkdir -p .claude/skills
cp -R node_modules/aiur-archon/dist/skills/archon-doc .claude/skills/archon-doc
```

## Start a document

Copy the skeleton into a directory that does not exist yet. `cp -R` into an existing directory nests the skeleton at `my-doc/skeleton/`, and the build then reports a missing `doc.json`.

```bash
cp -R node_modules/aiur-archon/dist/skeleton my-doc
```

| File | What to write |
| --- | --- |
| `my-doc/doc.json` | Replace every placeholder: a fresh six-hex `id` (`openssl rand -hex 3`), a unique `slug`, and real `title`, `heading`, `lede`, `eyebrow`, `status`, `meta` and `footer` values. |
| `my-doc/sections/*.html` | One HTML fragment per section, ordered by filename. Each starts with a metadata comment carrying the required `id`, `label` and `summary`, then an optional `peek` block for the closed state, then the body. |

The builder does not check that you replaced the skeleton's `id` and `slug`. A document still carrying them builds green, and the collision only surfaces later.

## First build

```bash
npx --no archon my-doc
```

| Command | Writes |
| --- | --- |
| `npx --no archon my-doc` | `my-doc/dist/my-doc.html`, the normal profile. |
| `npx --no archon my-doc --hosted` | `my-doc/dist/my-doc.hosted.html`, the profile you publish. It keeps the inlined theme, section navigation, anchors and changelog, and drops the comment, edit, presence and share clients. |

The file is named after the directory, not the `slug`. The command prints the path it wrote, then reports tag balance and size.

The build fails on:

- a missing `title` in `doc.json`;
- a section missing `id`, `label` or `summary`;
- two sections sharing an `id`;
- an unfilled layout placeholder.

Open the file in a browser. Each section shows its summary while closed and opens to its body, with a theme toggle and section navigation around it. [How Archon works](https://archon.aiur.team/how-archon-works/) is a finished example.

## Publish

Publishing is optional, and runs only with a service origin the person gives you.

A human approves each publication in their own browser:

| Step | What happens |
| --- | --- |
| `npx --no archon-publish start --file my-doc/dist/my-doc.hosted.html --title "My document" --service <origin> --json` | Exits `10` with a `verificationUrl`, a `userCode`, an `expiresAt` time and a `requestFile`. |
| The person opens the link | They sign in, check the pairing code, read the title and byte count, and approve. If the link is lost, `/publish/approve` takes the pairing code and `/publish/pending` lists their waiting publications. |
| `npx --no archon-publish resume --request <requestFile> --json` | Uploads once approval lands. Exits `0` with a receipt whose `result.url` is the link. |

A deployment with publishing switched off answers `start` with `503 publishing_disabled`. That is the operator's choice: keep the built HTML as the deliverable.

## Core commands

| Command | What it does |
| --- | --- |
| `npx --no archon --help` | Show the builder's synopsis. |
| `npx --no archon <dir>` | Build the normal profile into `<dir>/dist/<dir>.html`. |
| `npx --no archon <dir> --hosted` | Build the publishable profile into `<dir>/dist/<dir>.hosted.html`. |
| `npx --no archon-publish start … --json` | Start a publication and return the approval link. |
| `npx --no archon-publish status --request <file> --json` | Observe a publication once; never uploads. |
| `npx --no archon-publish resume --request <file> --json` | Wait for approval (60 seconds by default, up to 300 with `--timeout-seconds`), then upload. |
| `npx --no archon-publish cancel --request <file> --json` | Cancel a publication that has not completed. |

| Exit code | Meaning |
| --- | --- |
| `0` | Complete. Report `result.url`. |
| `10` | A checkpoint, not a failure: pending or approved. Wait, then `resume` with the same request file. |
| `20` | Denied or cancelled. Terminal. |
| `21` | The approval window or the 24-hour receipt window expired. |
| `22` | Local input, request-state or protocol error. Nothing was published. |
| `23` | Retryable service or network condition. Wait before running it again. |

Always pass `--json`: without it stdout is empty and the summary goes to stderr. To run your own deployment, see the [Archon README](https://github.com/aiur-team/archon#run-one).
