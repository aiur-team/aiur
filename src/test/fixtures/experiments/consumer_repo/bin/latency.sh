#!/bin/sh
set -eu
printf '{"unit_id":"request-1","value":42,"at":"%s","attrs":{}}\n' "$AIUR_EXPERIMENT_WINDOW_START"
printf '{"unit_id":"request-2","value":57,"at":"%s","attrs":{}}\n' "$AIUR_EXPERIMENT_WINDOW_START"
