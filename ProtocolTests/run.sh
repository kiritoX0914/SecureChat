#!/bin/bash
# Build and run the headless protocol test on macOS.
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
mkdir -p "$WORK/src"
cp SecureChat/Models/Models.swift SecureChat/Crypto/*.swift SecureChat/Network/*.swift \
   SecureChat/Core/PersistenceManager.swift "$WORK/src/"
sed 's/^import UIKit$//' SecureChat/Core/ChatManager.swift > "$WORK/src/ChatManager.swift"
cp ProtocolTests/UIKitShim.swift ProtocolTests/main.swift "$WORK/src/"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" -o "$WORK/harness" "$WORK"/src/*.swift || exit 1

head -c 3500000 /dev/urandom > "$WORK/testfile.bin"
export SC_TEST_FILE="$WORK/testfile.bin"
export SC_TEST_SHA=$(shasum -a 256 "$WORK/testfile.bin" | cut -d' ' -f1)

for r in A B C; do mkdir -p "$WORK/home-$r/Documents" "$WORK/home-$r/Library/Preferences" "$WORK/home-$r/Library/Application Support"; done

runrole() { # role home
  HOME="$WORK/home-$2" CFFIXED_USER_HOME="$WORK/home-$2" "$WORK/harness" "$1" "$WORK" > "$WORK/$1.log" 2>&1
  echo $? > "$WORK/$1.exit"
}
runrole A A & 
sleep 0.5; runrole B B &
sleep 0.5; runrole C C &
# B exits at ~43 s; restart it at ~52 s with the same data directory.
sleep 51
runrole B2 B &
wait
FAIL=0
for r in A B C B2; do
  echo "================ $r (exit $(cat $WORK/$r.exit)) ================"
  grep -E "PASS|FAIL|RESULT|conv |msg " "$WORK/$r.log"
  [ "$(cat $WORK/$r.exit)" = "0" ] || FAIL=1
done
echo "---- full logs: $WORK"
if [ $FAIL != 0 ]; then
  for r in A B C B2; do echo "######## $r full"; grep -v "^\s*$" "$WORK/$r.log" | tail -150; done
fi
exit $FAIL
