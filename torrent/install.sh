#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════════
# Torrent TUI Installer
# ════════════════════════════════════════════════════════════════════════════════
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/vinhnxv/rune/main/torrent/install.sh | bash
#
# Or with options:
#   curl -fsSL https://raw.githubusercontent.com/vinhnxv/rune/main/torrent/install.sh | bash -s -- --prefix ~/.local
#
# Options:
#   --prefix DIR     Install prefix (default: ~/.local for user install, /usr/local for system)
#   --system         Install to /usr/local/bin (may require sudo)
#   --no-tmux-check  Skip tmux installation check
#   --help           Show this help
# ════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
REPO_OWNER="vinhnxv"
REPO_NAME="rune"
BINARY_NAME="torrent"
GITHUB_API="https://api.github.com"
GITHUB_RELEASES="https://github.com"

# Default values
PREFIX=""
SYSTEM_INSTALL=false
NO_TMUX_CHECK=false

# Colors (only if terminal supports them)
if [[ -t 1 ]] && command -v tput &>/dev/null; then
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  BOLD=$(tput bold)
  RESET=$(tput sgr0)
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  BOLD=""
  RESET=""
fi

# ── Helper Functions ────────────────────────────────────────────────────────────
info() { echo "${BLUE}ℹ${RESET} $*"; }
success() { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}⚠${RESET} $*" >&2; }
error() { echo "${RED}✗${RESET} $*" >&2; }
die() { error "$*"; exit 1; }

cmd_exists() { command -v "$1" &>/dev/null; }

get_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) die "Unsupported architecture: $arch" ;;
  esac
}

get_os() {
  local os
  os=$(uname -s)
  case "$os" in
    Darwin) echo "apple-darwin" ;;
    Linux) echo "unknown-linux-gnu" ;;
    *) die "Unsupported OS: $os" ;;
  esac
}

show_help() {
  sed -n '2,12p' "$0" | sed 's/^# \?//'
  exit 0
}

# ── Parse Arguments ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --system)
      SYSTEM_INSTALL=true
      shift
      ;;
    --no-tmux-check)
      NO_TMUX_CHECK=true
      shift
      ;;
    --help|-h)
      show_help
      ;;
    *)
      warn "Unknown option: $1"
      shift
      ;;
  esac
done

# ── Determine Install Prefix ───────────────────────────────────────────────────
if [[ -z "$PREFIX" ]]; then
  if [[ "$SYSTEM_INSTALL" == "true" ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="$HOME/.local"
  fi
fi

INSTALL_DIR="$PREFIX/bin"

# ── Prerequisite Checks ────────────────────────────────────────────────────────
info "Checking prerequisites..."

# curl
if ! cmd_exists curl; then
  die "curl is required. Install with: brew install curl (macOS) or apt install curl (Linux)"
fi

# tmux
if [[ "$NO_TMUX_CHECK" != "true" ]] && ! cmd_exists tmux; then
  warn "tmux is not installed."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    info "Install with: brew install tmux"
  else
    info "Install with: apt install tmux (Debian/Ubuntu) or yum install tmux (RHEL/CentOS)"
  fi
  die "tmux is required for torrent to work. Re-run with --no-tmux-check to skip this check."
fi

# ── Determine Version ───────────────────────────────────────────────────────────
info "Fetching release information..."

RELEASE_URL="$GITHUB_API/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
TAG=$(curl -fsSL "$RELEASE_URL" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
if [[ -z "$TAG" ]]; then
  die "Failed to fetch latest release tag"
fi

info "Installing torrent $TAG"

# ── Determine Download URL ──────────────────────────────────────────────────────
ARCH=$(get_arch)
OS=$(get_os)
ASSET_NAME="${BINARY_NAME}-${ARCH}-${OS}.tar.gz"
DOWNLOAD_URL="$GITHUB_RELEASES/$REPO_OWNER/$REPO_NAME/releases/download/$TAG/$ASSET_NAME"

# Check if pre-built binary exists
HTTP_CODE=$(curl -fsSL -o /dev/null -w "%{http_code}" "$DOWNLOAD_URL" || true)

if [[ "$HTTP_CODE" != "200" ]]; then
  warn "Pre-built binary not found for $ARCH-$OS"
  info "Falling back to building from source..."

  # Check for Rust
  if ! cmd_exists cargo; then
    warn "Rust/cargo not found. Install Rust from https://rustup.rs/"
    info "Then re-run this installer, or use:"
    info "  git clone https://github.com/$REPO_OWNER/$REPO_NAME.git"
    info "  cd $REPO_NAME/torrent && cargo build --release"
    die "Cannot build from source without Rust"
  fi

  # Build from source
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  info "Cloning repository..."
  git clone --depth 1 --branch "$TAG" "https://github.com/$REPO_OWNER/$REPO_NAME.git" "$TMP_DIR/repo"

  info "Building from source (this may take a few minutes)..."
  cd "$TMP_DIR/repo/torrent"
  cargo build --release

  BINARY_PATH="target/release/$BINARY_NAME"
else
  # Download pre-built binary
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  info "Downloading $ASSET_NAME..."
  curl -fsSL "$DOWNLOAD_URL" | tar xzf - -C "$TMP_DIR"
  BINARY_PATH="$TMP_DIR/$BINARY_NAME"
fi

# ── Install Binary ──────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"

if [[ -w "$INSTALL_DIR" ]]; then
  cp "$BINARY_PATH" "$INSTALL_DIR/$BINARY_NAME"
  chmod +x "$INSTALL_DIR/$BINARY_NAME"
else
  info "Need sudo to install to $INSTALL_DIR"
  sudo cp "$BINARY_PATH" "$INSTALL_DIR/$BINARY_NAME"
  sudo chmod +x "$INSTALL_DIR/$BINARY_NAME"
fi

# ── Verify Installation ─────────────────────────────────────────────────────────
if ! cmd_exists "$BINARY_NAME"; then
  if [[ "$INSTALL_DIR" == "$HOME/.local/bin" ]]; then
    warn "$INSTALL_DIR is not in your PATH"
    info "Add it to your shell config:"
    echo ""
    echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
    echo "  source ~/.zshrc"
    echo ""
    if [[ -f ~/.bashrc ]]; then
      echo "  # Or for bash:"
      echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
      echo "  source ~/.bashrc"
    fi
  fi
fi

# ── Success ────────────────────────────────────────────────────────────────────
success "Installed torrent to $INSTALL_DIR/$BINARY_NAME"
info "Run 'torrent --help' to get started"