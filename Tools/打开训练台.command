#!/bin/zsh
set -eu
cd "${0:A:h}/.."
url=http://127.0.0.1:8765
if curl -fsS "$url/_stcore/health" >/dev/null 2>&1; then
  open "$url"
else
  exec .venv/bin/streamlit run Tools/training_studio.py --server.address 127.0.0.1 --server.port 8765 --browser.serverAddress localhost --browser.gatherUsageStats false
fi
