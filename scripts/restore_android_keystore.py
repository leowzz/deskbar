#!/usr/bin/env python3
"""Validate and restore the existing Android release JKS without logging secrets."""
import base64
import binascii
import os
from pathlib import Path
import sys


def decode_keystore(value):
    try:
        data = base64.b64decode("".join(value.split()), validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("DESKBAR_ANDROID_KEYSTORE_BASE64 must contain Base64 of the release JKS file") from None
    if not data.startswith(b"\xfe\xed\xfe\xed"):
        raise ValueError("DESKBAR_ANDROID_KEYSTORE_BASE64 does not decode to a JKS keystore")
    return data


def restore_keystore(path):
    data = decode_keystore(os.environ.get("DESKBAR_ANDROID_KEYSTORE_BASE64", ""))
    with open(path, "wb", opener=lambda name, flags: os.open(name, flags, 0o600)) as stream:
        stream.write(data)
    path.chmod(0o600)


if __name__ == "__main__":
    try:
        restore_keystore(Path(sys.argv[1]))
    except (ValueError, OSError) as error:
        sys.exit(f"Android signing: {error}")
