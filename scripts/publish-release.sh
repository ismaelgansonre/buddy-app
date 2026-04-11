#!/bin/bash
set -euo pipefail

# Usage: ./scripts/publish-release.sh <version> [build-number]
# Example: ./scripts/publish-release.sh 1.0.0

VERSION="${1:?Usage: publish-release.sh <version> [build-number]}"
BUILD_NUMBER="${2:-$(date +%Y%m%d%H%M)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
DMG_PATH="$BUILD_DIR/Buddy.dmg"
APPCAST="$ROOT/appcast.xml"
GITHUB_REPO="rahamanbinujit/buddy-app"

echo "=== Buddy Release v${VERSION} (build ${BUILD_NUMBER}) ==="
echo ""

# Step 1: Build the DMG
echo "[1/6] Building app and creating DMG..."
"$ROOT/scripts/build-app.sh"

if [ ! -f "$DMG_PATH" ]; then
    echo "Error: DMG not found at $DMG_PATH"
    exit 1
fi

# Step 2: Sign DMG with Sparkle Ed25519 key
echo "[2/6] Signing DMG with Sparkle Ed25519..."

# Find sign_update in Sparkle checkout
SIGN_TOOL=""
for candidate in \
    "$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
    "$ROOT/.build/checkouts/Sparkle/bin/sign_update" \
    "$(which sign_update 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        SIGN_TOOL="$candidate"
        break
    fi
done

if [ -z "$SIGN_TOOL" ]; then
    echo "Error: Sparkle sign_update tool not found."
    echo "Make sure Sparkle is resolved: cd $ROOT && swift package resolve"
    echo "Or install it manually: brew install sparkle"
    exit 1
fi

# sign_update outputs: sparkle:edSignature="..." length="..."
SIGN_OUTPUT=$("$SIGN_TOOL" "$DMG_PATH" 2>&1)
SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | head -1 | sed 's/sparkle:edSignature="//;s/"//')
FILE_LENGTH=$(stat -f%z "$DMG_PATH")

if [ -z "$SIGNATURE" ]; then
    echo "Error: Could not generate Ed25519 signature."
    echo "Make sure your private key exists at ~/Library/Sparkle/ed25519-private-key"
    echo "sign_update output: $SIGN_OUTPUT"
    exit 1
fi

echo "  Signature: ${SIGNATURE:0:20}..."
echo "  File size: $FILE_LENGTH bytes"

# Step 3: Update appcast.xml
echo "[3/6] Updating appcast.xml..."

PUB_DATE=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/Buddy.dmg"

# Build the new item XML
NEW_ITEM="        <item>\n            <title>Version ${VERSION}</title>\n            <pubDate>${PUB_DATE}</pubDate>\n            <enclosure\n                url=\"${DOWNLOAD_URL}\"\n                sparkle:version=\"${BUILD_NUMBER}\"\n                sparkle:shortVersionString=\"${VERSION}\"\n                sparkle:edSignature=\"${SIGNATURE}\"\n                length=\"${FILE_LENGTH}\"\n                type=\"application/octet-stream\" />\n        </item>"

# Insert before </channel>
if grep -q "<!-- Releases will be added here" "$APPCAST"; then
    # First release: replace the comment
    sed -i '' "s|        <!-- Releases will be added here when publishing updates -->|${NEW_ITEM}|" "$APPCAST"
else
    # Subsequent releases: insert before </channel>
    sed -i '' "s|    </channel>|${NEW_ITEM}\n    </channel>|" "$APPCAST"
fi

echo "  Updated appcast.xml"

# Step 4: Commit and tag
echo "[4/6] Committing and tagging..."
cd "$ROOT"
git add appcast.xml
git commit -m "Release v${VERSION}" || echo "  Nothing new to commit"
git tag -a "v${VERSION}" -m "Buddy v${VERSION}" 2>/dev/null || echo "  Tag v${VERSION} already exists"

# Step 5: Push to GitHub
echo "[5/6] Pushing to GitHub..."
git push origin main --tags

# Step 6: Create GitHub release
echo "[6/6] Creating GitHub release..."
gh release create "v${VERSION}" "$DMG_PATH" \
    --title "Buddy v${VERSION}" \
    --notes "Buddy v${VERSION} — AI desktop companion for macOS.

Download Buddy.dmg, open it, and drag Buddy to your Applications folder.

**What's new:**
- Free AI chat powered by Gemini (100K tokens/day)
- Sign in with just your email (magic link)
- Auto-updates built in
" \
    --repo "$GITHUB_REPO"

echo ""
echo "=== Released v${VERSION}! ==="
echo "  DMG:     $DMG_PATH"
echo "  Release: https://github.com/${GITHUB_REPO}/releases/tag/v${VERSION}"
echo "  Feed:    https://raw.githubusercontent.com/${GITHUB_REPO}/main/appcast.xml"
