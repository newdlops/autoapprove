#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
AUTOAPPROVE_BUILD="${AUTOAPPROVE_BUILD:-release}"
swift build --disable-sandbox --cache-path .build/cache -c "$AUTOAPPROVE_BUILD"
mkdir -p dist
npm --prefix extensions/vscode ci
npm --prefix extensions/vscode run package
node scripts/package-app.mjs "$AUTOAPPROVE_BUILD"
