#!/usr/bin/env python3
"""Extract only the NDK sysroot from the remote NDK zip via HTTP Range requests.

Avoids downloading the full 717 MB archive (host clang binaries are ~600 MB of it).
"""
import http.client
import io
import os

ROOT = os.environ.get("AMDL_ROOT", "/root/workspace")
import sys
import time
import zipfile

HOST = "dl.google.com"
PATH = "/android/repository/android-ndk-r23b-linux.zip"
SIZE = 725122099
OUT = ROOT + "/ndk"


class HttpFile(io.RawIOBase):
    def __init__(self):
        super().__init__()
        self.pos = 0
        self.conn = http.client.HTTPSConnection(HOST, timeout=90)
        self.reqs = 0
        self.bytes = 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        if whence == 0:
            self.pos = offset
        elif whence == 1:
            self.pos += offset
        else:
            self.pos = SIZE + offset
        return self.pos

    def readinto(self, buf):
        n = len(buf)
        if self.pos >= SIZE or n == 0:
            return 0
        n = min(n, SIZE - self.pos)
        data = self._get(self.pos, self.pos + n - 1)
        buf[: len(data)] = data
        self.pos += len(data)
        return len(data)

    def _get(self, start, end):
        last = None
        for _ in range(5):
            try:
                self.conn.request("GET", PATH, headers={"Range": f"bytes={start}-{end}"})
                resp = self.conn.getresponse()
                data = resp.read()
                if resp.status != 206:
                    raise IOError(f"status {resp.status}")
                if len(data) != end - start + 1:
                    raise IOError(f"short read {len(data)}")
                self.reqs += 1
                self.bytes += len(data)
                return data
            except Exception as exc:  # reconnect and retry
                last = exc
                try:
                    self.conn.close()
                except Exception:
                    pass
                self.conn = http.client.HTTPSConnection(HOST, timeout=90)
                time.sleep(1)
        raise IOError(f"range {start}-{end} failed: {last}")


def main():
    raw = HttpFile()
    zf = zipfile.ZipFile(io.BufferedReader(raw, buffer_size=1 << 16))
    wanted = [
        n
        for n in zf.namelist()
        if "/sysroot/usr/include/" in n
        or "/sysroot/usr/lib/aarch64-linux-android" in n
    ]
    print(f"entries to extract: {len(wanted)}", flush=True)
    done = 0
    t0 = time.time()
    for name in wanted:
        idx = name.index("/sysroot/")
        rel = name[idx + len("/sysroot/") :]
        dst = os.path.join(OUT, rel)
        if name.endswith("/"):
            os.makedirs(dst, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with zf.open(name) as src, open(dst, "wb") as out:
            while True:
                chunk = src.read(1 << 16)
                if not chunk:
                    break
                out.write(chunk)
        done += 1
        if done % 200 == 0:
            el = time.time() - t0
            print(
                f"[{done}/{len(wanted)}] {raw.bytes/1e6:.1f} MB in {el:.0f}s "
                f"({raw.reqs} reqs)",
                flush=True,
            )
    print(f"DONE {done} files, {raw.bytes/1e6:.1f} MB transferred, {raw.reqs} requests")


if __name__ == "__main__":
    sys.exit(main())
