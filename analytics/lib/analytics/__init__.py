"""Aiur analytics — canonical offline reducer and Executor report tooling.

This package reduces durable run-telemetry NDJSON streams into one
schema'd, regenerable per-boot summary (``run-summary.v1.json``) plus
per-build-order rollups (``build-summary.v1.json``), and renders those
summaries for Executors. It is deliberately dependency-free (stdlib only)
so the tools run on any host with a Python 3 interpreter.
"""

__version__ = "1.0.0"
