#!/bin/bash
# 使用本机钥匙串中的固定证书签名；证书不可用时停止，不回退到临时签名。
set -euo pipefail
if [[ $# -ne 1 || ! -d "$1/Contents" ]]; then
    echo 'Usage: scripts/sign-local.sh /path/to/Thaw.app' >&2
    exit 2
fi
identity_file="$HOME/Library/Application Support/ThawSigning/identity.txt"
if [[ ! -f "$identity_file" ]]; then
    echo 'Missing local signing configuration. Configure the existing Thaw certificate first.' >&2
    exit 1
fi
identity=$(tr -d '[:space:]' < "$identity_file")
if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo 'Invalid local certificate fingerprint.' >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -Fq "$identity"; then
    echo 'The configured signing certificate is unavailable or untrusted; refusing ad-hoc signing.' >&2
    exit 1
fi
codesign --force --deep --sign "$identity" --timestamp=none "$1"
codesign --verify --deep --strict "$1"
codesign -d -r- "$1"
