#!/usr/bin/env python3
"""Serialize publishing and consuming the per-config pending report marker."""
import argparse
import fcntl
import os
from pathlib import Path
import sys
import tempfile


def check_file(path):
    if path.is_symlink() or path.exists() and (not path.is_file() or path.stat().st_nlink != 1):
        raise ValueError(f"refusing linked or non-regular report state: {path}")


def update(path, report=None):
    path = Path(path)
    lock = path.with_name(path.name + ".lock")
    check_file(lock)
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as stream:
        if os.fstat(stream.fileno()).st_nlink != 1:
            raise ValueError("report lock must not be hard-linked")
        fcntl.flock(stream, fcntl.LOCK_EX)
        check_file(path)
        if report is None:
            try:
                content = path.read_text().strip()
            except FileNotFoundError:
                return ""
            path.unlink()
            return content
        fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as output:
                output.write(report + "\n")
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("put", "take"))
    parser.add_argument("path")
    parser.add_argument("report", nargs="?")
    args = parser.parse_args()
    if args.action == "put" and not args.report:
        parser.error("put requires a non-empty report path")
    try:
        result = update(args.path, args.report if args.action == "put" else None)
        if result:
            print(result)
        return 0
    except (OSError, ValueError) as exc:
        print(f"report_state: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
