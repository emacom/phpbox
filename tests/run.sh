#!/usr/bin/env bash
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-unit}" in
  unit)  exec bash "$TESTS_DIR/unit.sh" ;;
  smoke) shift; exec bash "$TESTS_DIR/smoke.sh" "$@" ;;
  *)     echo "Usage: tests/run.sh [unit | smoke [platform] [version]]"; exit 1 ;;
esac
