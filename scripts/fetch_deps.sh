#!/bin/bash
# 拉取构建依赖源码：cJSON（版本与上游 wrapper 一致）与 Dobby（固定 commit）
set -eu
cd "$(dirname "$0")/.."

fetch() {  # url, target-dir, strip
  python3 - "$1" "$2" "$3" <<'PY'
import io, os, sys, tarfile, urllib.request
url, dest, strip = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(f"下载 {url}")
data = urllib.request.urlopen(url, timeout=120).read()
os.makedirs(dest, exist_ok=True)
with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
    for m in tf.getmembers():
        parts = m.name.split("/", strip)
        if len(parts) <= strip:
            continue
        m.name = "/".join(parts[strip:])
        if m.name:
            tf.extract(m, dest)
print(f"→ {dest}")
PY
}

[ -d cjson ] || fetch https://codeload.github.com/DaveGamble/cJSON/tar.gz/refs/tags/v1.7.19 cjson 1
[ -d dobby ] || fetch https://codeload.github.com/BepInEx/Dobby/tar.gz/9d271803881f467aabfc24593c7dcaeb710fe861 dobby 1
echo "依赖源码就绪：cjson/ dobby/"
