#!/bin/bash
# Construye Rescate en out/ usando un contenedor Fedora (no necesita root).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
podman run --rm --privileged -v "$PWD/src:/src:ro,Z" -v "$PWD/out:/out:Z" \
  registry.fedoraproject.org/fedora:44 bash /src/build-in-container.sh
