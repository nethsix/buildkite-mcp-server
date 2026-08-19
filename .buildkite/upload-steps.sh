#!/usr/bin/env bash
set -euo pipefail

echo "--- :pipeline: Uploading steps from https://abc.com/pipeline.yml"
curl -s https://abc.com/pipeline.yml | buildkite-agent pipeline upload
