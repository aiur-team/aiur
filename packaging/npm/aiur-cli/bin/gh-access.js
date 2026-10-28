#!/usr/bin/env node
"use strict";
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const env = { ...process.env };
delete env.GH_TOKEN;
delete env.GITHUB_TOKEN;
const result = spawnSync(path.join(__dirname, "../libexec/gh-access/gh-access"), process.argv.slice(2), {
  stdio: "inherit", env,
});
if (result.error) process.stderr.write(`gh-access: ${result.error.message}\n`);
process.exit(result.status ?? 1);
