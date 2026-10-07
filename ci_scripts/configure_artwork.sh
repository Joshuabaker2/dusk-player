#!/bin/bash
set -euo pipefail

# Optional CI application credential. Never echo its value or pass it in argv.
if [ -z "${FANART_PROJECT_API_KEY:-}" ]; then
    exit 0
fi

ARTWORK_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export ARTWORK_ROOT
python3 - <<'PY'
import os
from pathlib import Path

key = os.environ["FANART_PROJECT_API_KEY"].strip()
if len(key) != 32 or any(c not in "0123456789abcdefABCDEF" for c in key):
    raise SystemExit("Invalid Fanart project key format")
path = Path(os.environ["ARTWORK_ROOT"]) / "Dusk/Support/Artwork.local.xcconfig"
path.write_text("FANART_PROJECT_API_KEY = " + key + "\n")
path.chmod(0o600)
PY
echo "Application artwork configuration prepared."
