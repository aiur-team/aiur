---
name: design-import
description: Import large design artifacts into a writable workspace without overflowing inline tool-result limits. Use when an agent needs claude_design, a Claude Design URL/file, a large HTML design export, or any design payload that may exceed 100 KiB; especially before frontend-design implementation or re-import work.
---

# Import designs to disk

Land the source artifact on disk before interpreting or implementing it. Do not
request a large design document inline and do not retry an inline read after an
overflow.

## Workflow

1. Create a ticket-local, ignored import directory in the writable workspace.
   Keep imported source artifacts out of commits unless the ticket explicitly
   requires them as product assets.
2. Ensure the Claude CLI is authenticated for the design MCP (`/design-login`
   when required).
3. From the ticket workspace, start an authenticated `claude --print` session
   with workspace write permission. In its prompt, provide the design URL and
   file name, tell it to call `claude_design`, write the complete returned
   artifact to the chosen workspace path, and return only the path, byte count,
   and SHA-256. Do not ask it to echo the artifact in its response.
4. If the CLI/MCP supports returning the raw artifact on stdout without a prose
   wrapper, redirect stdout directly to the workspace file instead. Never
   redirect an unknown conversational response and assume it is the design.
5. Verify that the file exists, is non-empty, has a plausible type/size, and
   record its SHA-256. Read or search it from disk in bounded chunks.
6. Continue the frontend-design workflow from the local artifact. If the design
   is re-imported, diff the saved source against the prior import rather than
   rebuilding blindly.

## Recovery rules

- If an Aiur dynamic-tool result says it was saved under
  `.aiur-runtime/tool-results/`, use that path and continue; do not repeat the
  call. Aiur installs a repository-local Git exclusion for this owner-only
  runtime directory.
- If a direct MCP call already overflowed, stop using that thread for inline
  reads. Run the disk-first Claude session from the same workspace; a manual
  agent restart is not required.
- If one-shot persistence is unavailable, request bounded ranges/sections and
  append them to the workspace file, verifying completeness before use.
- Keep credentials out of prompts, shell history, saved artifacts, and commits.
