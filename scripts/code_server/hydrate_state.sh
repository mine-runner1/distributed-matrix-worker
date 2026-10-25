#!/usr/bin/env bash
# ==============================================================================
# Standalone Code-Server State Hydration Engine
# Restores full workspace, .claude chat sessions, configs, and shell setups
# 100% Host-Safe: Zero OpenSSH Daemons, Zero Port 22 Listeners, Zero Backdoors
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-gdrive:coolify-relay-state/code_server-state}"
LEGACY_VOLUMES_TARGET="gdrive:coolify-relay-state/coolify-state/volumes_bundle.tar.gz"
STAGE_DIR="/tmp/code_server_stage"
WORKSPACE_DIR="/home/runner/workspace"
CLAUDE_DIR="/home/runner/.claude"
CONFIG_DIR="/home/runner/.config/code-server"

echo "[HYDRATE] === Initializing Standalone Code-Server Environment ==="

mkdir -p "$STAGE_DIR" "$WORKSPACE_DIR" "$CLAUDE_DIR" "$CONFIG_DIR"
sudo chown -R runner:docker "$WORKSPACE_DIR" "$CLAUDE_DIR" /home/runner/.config /home/runner/.local 2>/dev/null || true

# 1. Check for dedicated Code-Server State Archive first
echo "[HYDRATE] Checking for existing code_server_bundle.tar.gz on cloud storage..."
if rclone check "$STORAGE_TARGET/code_server_bundle.tar.gz" "$STAGE_DIR" --one-way 2>/dev/null || rclone ls "$STORAGE_TARGET/code_server_bundle.tar.gz" >/dev/null 2>&1; then
  echo "[HYDRATE] Found active code_server_bundle.tar.gz. Downloading..."
  rclone copyto "$STORAGE_TARGET/code_server_bundle.tar.gz" "$STAGE_DIR/code_server_bundle.tar.gz" \
    --drive-chunk-size=256M --buffer-size=64M --retries=5 --timeout=3m

  echo "[HYDRATE] Extracting full workspace, .claude chats, and environment configs..."
  if command -v pigz >/dev/null 2>&1; then
    pigz -dc "$STAGE_DIR/code_server_bundle.tar.gz" | tar -xpf - -C /home/runner
  else
    tar -xzpf "$STAGE_DIR/code_server_bundle.tar.gz" -C /home/runner
  fi
  echo "[HYDRATE] Native code-server state restored successfully!"

# 2. Migration Path: Extract from legacy Coolify Docker volumes bundle
elif rclone ls "$LEGACY_VOLUMES_TARGET" >/dev/null 2>&1; then
  echo "[HYDRATE] First boot migration: Found legacy volumes_bundle.tar.gz from Coolify. Downloading..."
  rclone copyto "$LEGACY_VOLUMES_TARGET" "$STAGE_DIR/volumes_bundle.tar.gz" \
    --drive-chunk-size=256M --buffer-size=64M --retries=5 --timeout=3m

  MIGRATE_TEMP="/tmp/legacy_volume_extract"
  mkdir -p "$MIGRATE_TEMP"
  echo "[HYDRATE] Unpacking legacy volumes to search for /config, /workspace, and .claude..."
  if command -v pigz >/dev/null 2>&1; then
    pigz -dc "$STAGE_DIR/volumes_bundle.tar.gz" | tar -xpf - -C "$MIGRATE_TEMP" 2>/dev/null || true
  else
    tar -xzpf "$STAGE_DIR/volumes_bundle.tar.gz" -C "$MIGRATE_TEMP" 2>/dev/null || true
  fi

  # Search for code-server volume contents across extracted volumes
  echo "[HYDRATE] Locating code-server files in extracted volumes..."
  FOUND_CONFIG=$(find "$MIGRATE_TEMP" -type d \( -name ".claude" -o -name "code-server" -o -name "workspace" \) 2>/dev/null | head -n 1 || true)

  if [ -n "$FOUND_CONFIG" ]; then
    ROOT_CONTAINER_DIR=$(dirname "$FOUND_CONFIG")
    echo "[HYDRATE] Detected container root at $ROOT_CONTAINER_DIR. Migrating..."

    # Restore .claude chats and settings if present
    if [ -d "$ROOT_CONTAINER_DIR/.claude" ]; then
      echo "[HYDRATE] Restoring Claude Code history and sessions..."
      cp -a "$ROOT_CONTAINER_DIR/.claude/." "$CLAUDE_DIR/" 2>/dev/null || true
    fi
    [ -f "$ROOT_CONTAINER_DIR/.claude.json" ] && cp -a "$ROOT_CONTAINER_DIR/.claude.json" "/home/runner/" 2>/dev/null || true

    # Restore workspace projects
    if [ -d "$ROOT_CONTAINER_DIR/workspace" ]; then
      echo "[HYDRATE] Restoring workspace projects..."
      cp -a "$ROOT_CONTAINER_DIR/workspace/." "$WORKSPACE_DIR/" 2>/dev/null || true
    elif [ -d "$ROOT_CONTAINER_DIR/project" ]; then
      cp -a "$ROOT_CONTAINER_DIR/project/." "$WORKSPACE_DIR/" 2>/dev/null || true
    fi

    # Restore any setup scripts in root
    find "$ROOT_CONTAINER_DIR" -maxdepth 2 -type f -name "*.sh" -exec cp -a {} "$WORKSPACE_DIR/" \; 2>/dev/null || true
  else
    echo "[HYDRATE] Notice: No direct code-server volume found in legacy tarball. Defaulting to fresh workspace."
  fi
  rm -rf "$MIGRATE_TEMP"
fi

# 3. Ensure permissions and directories are clean
sudo chown -R runner:docker "$WORKSPACE_DIR" "$CLAUDE_DIR" /home/runner/.config /home/runner/.local 2>/dev/null || true
echo "[HYDRATE] Hydration complete. Workspace ready at $WORKSPACE_DIR."
