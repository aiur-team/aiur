#!/bin/sh
set -eu

install -d -m 700 /root/.ssh /root/.codex

if [ ! -s /run/aiur/ssh/authorized_key.pub ]; then
  echo "missing authorized key at /run/aiur/ssh/authorized_key.pub" >&2
  exit 1
fi

install -m 600 /run/aiur/ssh/authorized_key.pub /root/.ssh/authorized_keys

exec /usr/sbin/sshd -D -e
