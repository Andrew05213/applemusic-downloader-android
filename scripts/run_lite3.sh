#!/bin/bash
set -u
. "$(dirname "$0")/env_lite3.sh"
exec "$LITE_BIN" --native-service --base-dir "$ANDROID_DATA" --host 127.0.0.1 --port 12341
