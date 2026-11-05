#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
if [[ "$developer_dir" == *.app/Contents/Developer ]]; then
  testing_frameworks="$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"
fi
exec swift test --disable-sandbox --disable-xctest \
  -Xswiftc -F -Xswiftc "$testing_frameworks" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker "$testing_frameworks" \
  -Xlinker -rpath -Xlinker "$testing_frameworks" "$@"
