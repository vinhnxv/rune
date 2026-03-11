#!/bin/bash
# Bootstrap a standalone Storybook environment at tmp/storybook/
#
# Usage:
#   bootstrap.sh [--src-dir DIR]        Copy component directories from DIR into src/
#   bootstrap.sh [--story-files FILE..] Copy individual story files into src/stories/
#   bootstrap.sh                        Scaffold only (no files copied)
#
# Modes:
#   design-prototype: --src-dir tmp/design-prototype/{ts}/prototypes
#   arc storybook:    --story-files path/to/Component.stories.tsx ...
#   standalone:       just scaffold + install
#
# The tmp/storybook/ directory is ephemeral — cleaned by /rune:rest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
STORYBOOK_DIR="${PROJECT_ROOT}/tmp/storybook"

# Parse arguments
SRC_DIR=""
STORY_FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --src-dir)
      SRC_DIR="${2:-}"
      shift 2
      ;;
    --story-files)
      shift
      while [ $# -gt 0 ] && [[ ! "$1" == --* ]]; do
        STORY_FILES+=("$1")
        shift
      done
      ;;
    *)
      # Legacy: first positional arg = src-dir (backward compat)
      if [ -z "$SRC_DIR" ] && [ -d "$1" ]; then
        SRC_DIR="$1"
      fi
      shift
      ;;
  esac
done

# ── Phase 1: Scaffold ──────────────────────────────────────────────────
# Create the Storybook project structure if it doesn't exist yet.
# This only runs once per session — subsequent calls reuse the scaffold.

if [ ! -f "${STORYBOOK_DIR}/package.json" ]; then
  echo "Bootstrapping Storybook at tmp/storybook/ ..."
  mkdir -p "${STORYBOOK_DIR}/.storybook" "${STORYBOOK_DIR}/src"

  # package.json
  cat > "${STORYBOOK_DIR}/package.json" << 'PKGJSON'
{
  "name": "rune-storybook-preview",
  "version": "1.0.0",
  "private": true,
  "description": "Ephemeral Storybook for Rune prototype and component preview",
  "scripts": {
    "storybook": "storybook dev -p 6006",
    "build-storybook": "storybook build"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1"
  },
  "devDependencies": {
    "@storybook/react": "^10.2.13",
    "@storybook/react-vite": "^10.2.13",
    "storybook": "^10.2.13",
    "tailwindcss": "^4.0.0",
    "@tailwindcss/vite": "^4.0.0",
    "typescript": "^5.7.0",
    "vite": "^6.0.0",
    "@types/react": "^18.3.0",
    "@types/react-dom": "^18.3.0",
    "@storybook/addon-docs": "^10.2.13"
  }
}
PKGJSON

  # .storybook/main.ts
  cat > "${STORYBOOK_DIR}/.storybook/main.ts" << 'MAIN'
import type { StorybookConfig } from "@storybook/react-vite";

const config: StorybookConfig = {
  stories: ["../src/**/*.stories.@(ts|tsx)"],
  addons: ["@storybook/addon-docs"],
  framework: {
    name: "@storybook/react-vite",
    options: {},
  },
};

export default config;
MAIN

  # .storybook/preview.ts
  cat > "${STORYBOOK_DIR}/.storybook/preview.ts" << 'PREVIEW'
import type { Preview } from "@storybook/react-vite";
import "../src/index.css";

const preview: Preview = {
  parameters: {
    layout: "fullscreen",
  },
};

export default preview;
PREVIEW

  # vite.config.ts
  cat > "${STORYBOOK_DIR}/vite.config.ts" << 'VITE'
import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [tailwindcss()],
});
VITE

  # src/index.css (Tailwind v4)
  echo '@import "tailwindcss";' > "${STORYBOOK_DIR}/src/index.css"

  # .gitignore
  cat > "${STORYBOOK_DIR}/.gitignore" << 'GITIGNORE'
node_modules/
storybook-static/
GITIGNORE

  echo "Scaffold created."
fi

# ── Phase 2: Install dependencies ──────────────────────────────────────
if [ ! -d "${STORYBOOK_DIR}/node_modules" ]; then
  if ! command -v npm >/dev/null 2>&1; then
    echo '{"error": "npm not found — install Node.js to use Storybook", "ready": false}'
    exit 0
  fi
  echo "Installing dependencies ..."
  if ! (cd "${STORYBOOK_DIR}" && npm install --legacy-peer-deps --loglevel=error); then
    echo '{"error": "npm install failed", "ready": false}'
    exit 0
  fi
  echo "Dependencies installed."
fi

# ── Phase 3A: Copy prototype directories (design-prototype mode) ───────
if [ -n "${SRC_DIR}" ] && [ -d "${SRC_DIR}" ]; then
  # Clean previous prototypes but keep other src/ content (stories, etc)
  rm -rf "${STORYBOOK_DIR}/src/prototypes"
  mkdir -p "${STORYBOOK_DIR}/src/prototypes"

  for comp_dir in "${SRC_DIR}"/*/; do
    if [ -d "$comp_dir" ]; then
      comp_name="$(basename "$comp_dir")"
      # SEC-002: reject path traversal
      case "$comp_name" in
        *..* | */*) continue ;;
      esac
      cp -r "$comp_dir" "${STORYBOOK_DIR}/src/prototypes/${comp_name}"
    fi
  done

  proto_count=$(find "${STORYBOOK_DIR}/src/prototypes" -name "prototype.tsx" 2>/dev/null | wc -l | tr -d ' ')
  story_count=$(find "${STORYBOOK_DIR}/src/prototypes" -name "*.stories.tsx" 2>/dev/null | wc -l | tr -d ' ')
  echo "Copied ${proto_count} prototypes with ${story_count} stories to src/prototypes/."
fi

# ── Phase 3B: Copy individual story files (arc testing mode) ───────────
if [ ${#STORY_FILES[@]} -gt 0 ]; then
  mkdir -p "${STORYBOOK_DIR}/src/components"

  copied=0
  for story_file in "${STORY_FILES[@]}"; do
    if [ -f "$story_file" ]; then
      base_name="$(basename "$story_file")"
      # SEC-002: reject path traversal
      case "$base_name" in
        *..* | */*) continue ;;
      esac
      cp "$story_file" "${STORYBOOK_DIR}/src/components/${base_name}"

      # Also copy the component file if it exists alongside the story
      comp_file="${story_file%.stories.tsx}.tsx"
      if [ -f "$comp_file" ]; then
        cp "$comp_file" "${STORYBOOK_DIR}/src/components/$(basename "$comp_file")"
      fi
      copied=$((copied + 1))
    fi
  done
  echo "Copied ${copied} story files to src/components/."
fi

# ── Phase 4: Detect full-page component ────────────────────────────────
# Find the component that imports >= 2 sibling prototypes (= full screen)
full_page=""
if [ -d "${STORYBOOK_DIR}/src/prototypes" ]; then
  for proto in "${STORYBOOK_DIR}/src/prototypes"/*/prototype.tsx; do
    [ -f "$proto" ] || continue
    comp_name="$(basename "$(dirname "$proto")")"
    import_count=$(grep -c 'from "\.\./.*\/prototype"' "$proto" 2>/dev/null || true)
    import_count="${import_count:-0}"
    import_count="$(echo "$import_count" | tr -d '[:space:]')"
    if [ "$import_count" -ge 2 ]; then
      full_page="$comp_name"
      break
    fi
  done
fi

# ── Phase 5: Server status ─────────────────────────────────────────────
server_running="false"
if lsof -ti:6006 > /dev/null 2>&1; then
  server_running="true"
fi

# Output result as JSON for the caller
cat << EOF
{
  "storybook_dir": "${STORYBOOK_DIR}",
  "full_page_component": "${full_page}",
  "server_running": ${server_running},
  "ready": true
}
EOF
