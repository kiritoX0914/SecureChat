#!/bin/bash
# Cross-implementation check: Swift app crypto <-> Python reference written from PROTOCOL.md
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=${1:-$(mktemp -d)}
mkdir -p "$OUT/src" "$OUT/home/Library/Preferences"
cp SecureChat/Models/Models.swift SecureChat/Crypto/SignalCrypto.swift SecureChat/Crypto/CryptoEngine.swift ProtocolTests/vectors/main.swift "$OUT/src/"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" -o "$OUT/vectors" "$OUT"/src/*.swift
export HOME="$OUT/home" CFFIXED_USER_HOME="$OUT/home"
"$OUT/vectors" gen "$OUT/PROTOCOL-vectors.json"
python3 -m venv "$OUT/venv" && "$OUT/venv/bin/pip" -q install cryptography
"$OUT/venv/bin/python" ProtocolTests/vectors/protocol_check.py "$OUT/PROTOCOL-vectors.json" "$OUT/python-replies.json"
"$OUT/vectors" verify "$OUT/python-replies.json"
