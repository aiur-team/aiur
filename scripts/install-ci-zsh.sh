#!/usr/bin/env bash
set -euo pipefail

if ! command -v zsh >/dev/null 2>&1; then
  sudo rm -f /etc/apt/sources.list.d/microsoft-prod.list
  sudo apt-get update
  sudo apt-get install -y zsh
fi
