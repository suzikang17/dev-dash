#!/bin/zsh
# Watches Sources/ for .swift changes and reruns run.sh on every save.
# Usage: ./watch.sh
# Stop: Ctrl-C

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo "→ Initial build and launch..."
./run.sh

echo "\nWatching Sources/ — save any .swift file to rebuild (Ctrl-C to stop)\n"

while true; do
    find Sources/ -name "*.swift" | entr -d sh -c "
        cd '$PROJECT_DIR'
        ./run.sh || echo '✗ Build failed'
    "
done
