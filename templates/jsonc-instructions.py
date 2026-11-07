#!/usr/bin/env python3
"""Add paths to the "instructions" array in opencode.jsonc without breaking the file.

Usage: jsonc-instructions.py <config> <path1> [path2 ...]
Exit: 0 = changed/already present · 3 = no instructions key (created) · 1 = error

Deliberately touches only one array; the rest of the file is left as-is
(// comments and trailing commas stay intact).
"""
import os
import re
import sys


def fail(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def main():
    if len(sys.argv) < 3:
        fail("usage: jsonc-instructions.py <config> <path...>")
    conf = sys.argv[1]
    paths = sys.argv[2:]

    try:
        src = open(conf, encoding="utf-8").read()
    except FileNotFoundError:
        fail("file not found: " + conf)

    m = re.search(r'"instructions"\s*:\s*\[(.*?)\]', src, re.S)
    if m:
        body = m.group(1)
        existing = re.findall(r'"([^"]+)"', body)
        missing = [p for p in paths if p not in existing]
        if not missing:
            print("NOTHING_TO_DO")
            return 0
        items = existing + missing
        new_body = "\n" + ",\n".join('    "%s"' % p for p in items) + "\n  "
        new = src[: m.start(1)] + new_body + src[m.end(1) :]
        tmp = conf + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(new)
        os.replace(tmp, conf)
        print("ADDED:" + ",".join(missing))
        return 0

    # no instructions key yet → insert it before the last '}'
    idx = src.rstrip().rfind("}")
    if idx < 0:
        fail("not a JSON object: " + conf)
    head = src[:idx].rstrip()
    tail = src[idx:]
    entry = '  "instructions": [\n' + ",\n".join('    "%s"' % p for p in paths) + "\n  ]\n"
    if head.rstrip().endswith("{"):
        new = head + "\n" + entry + tail
    else:
        if head.endswith(","):
            head = head[:-1]
        new = head + ",\n" + entry + tail
    tmp = conf + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(new)
    os.replace(tmp, conf)
    print("CREATED:" + ",".join(paths))
    return 3


if __name__ == "__main__":
    sys.exit(main())
