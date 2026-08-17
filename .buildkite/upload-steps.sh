#!/usr/bin/env bash
set -euo pipefail

echo "--- :pipeline: Uploading steps from .buildkite/steps.yml"
buildkite-agent pipeline upload .buildkite/steps.yml
