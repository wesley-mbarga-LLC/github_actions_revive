#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# Configurable Variables
# -----------------------
RUNNER_VERSION="${RUNNER_VERSION:-2.323.0}"

# Repo
GH_OWNER="${GH_OWNER:-s5wesley}"
GH_REPO="${GH_REPO:-github_actions_revive}"
REPO_URL="https://github.com/${GH_OWNER}/${GH_REPO}"

# Token (read from env; safer than hard-coding)
RUNNER_TOKEN="${RUNNER_TOKEN:?Set RUNNER_TOKEN (registration token from GitHub)}"

RUNNER_LABELS="${RUNNER_LABELS:-repo-build,repo-deploy}"
RUNNER_GROUP="${RUNNER_GROUP:-}"            # optional; leave empty to omit
RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_COUNT="${RUNNER_COUNT:-3}"
BASE_DIR="${BASE_DIR:-/opt/github-runner-multi}"
EPHEMERAL="${EPHEMERAL:-false}"             # set to "true" for one-job runners

# -----------------------
# Detect arch
# -----------------------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  PKG_ARCH="x64" ;;
  aarch64) PKG_ARCH="arm64" ;;
  *) echo "[ERROR] Unsupported arch: $ARCH"; exit 1 ;;
esac

# -----------------------
# Ensure prerequisites
# -----------------------
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar jq coreutils
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y curl tar jq coreutils
fi

# -----------------------
# Create system user (idempotent)
# -----------------------
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
  echo "[INFO] Creating system user: $RUNNER_USER"
  sudo useradd -m -s /bin/bash "$RUNNER_USER"
fi

# -----------------------
# Prepare base dir
# -----------------------
sudo mkdir -p "$BASE_DIR"
sudo chown "$RUNNER_USER:$RUNNER_USER" "$BASE_DIR"

RUNNER_TAR="actions-runner-linux-${PKG_ARCH}-${RUNNER_VERSION}.tar.gz"
RELEASE_BASE="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}"

# -----------------------
# Download runner tarball as RUNNER_USER
# -----------------------
sudo -u "$RUNNER_USER" bash -lc "
  set -e
  cd \"$BASE_DIR\"
  if [ ! -f \"$RUNNER_TAR\" ]; then
    echo \"[INFO] Downloading runner v$RUNNER_VERSION ($PKG_ARCH)\"
    curl -fsSL -o \"$RUNNER_TAR\" \"${RELEASE_BASE}/${RUNNER_TAR}\"
  else
    echo \"[INFO] Runner tarball already present: $RUNNER_TAR\"
  fi
"

# -----------------------
# Checksum verification
# -----------------------
if [ "$RUNNER_VERSION" = "2.323.0" ] && [ "$PKG_ARCH" = "x64" ]; then
  EXPECTED_SUM="0dbc9bf5a58620fc52cb6cc0448abcca964a8d74b5f39773b7afcad9ab691e19  $BASE_DIR/$RUNNER_TAR"
  echo "[INFO] Verifying checksum inline for v$RUNNER_VERSION $PKG_ARCH"
  printf '%s\n' "$EXPECTED_SUM" | sha256sum -c -
else
  echo "[INFO] Attempting checksum verification via sha256s.txt (fallback)"
  set +e
  sudo -u "$RUNNER_USER" bash -lc "
    cd '$BASE_DIR' &&
    curl -fsSL -o checksums.txt '${RELEASE_BASE}/sha256sums.txt' &&
    grep ' ${RUNNER_TAR}\$' checksums.txt > 'runner.sha256' &&
    sha256sum -c 'runner.sha256'
  "
  if [ $? -ne 0 ]; then
    echo '[WARN] Could not verify checksum via sha256sums.txt. Proceeding without verification.'
  fi
  set -e
fi

# -----------------------
# Install multiple runners (repo-scoped)
# -----------------------
for i in $(seq 1 "$RUNNER_COUNT"); do
  RUNNER_DIR="$BASE_DIR/runner-$i"

  # ----- Safe runner name (short hostname, <=64 chars) -----
  suffix="-RUNNER-$i"
  base="$(hostname -s)"   # short hostname, e.g., "wesley-vm"
  max=64
  avail=$(( max - ${#suffix} ))
  if [ $avail -lt 1 ]; then
    # Fallback: if suffix itself is too long (unlikely), trim it
    suffix="${suffix:0:$max}"
    base=""
  elif [ ${#base} -gt $avail ]; then
    base="${base:0:$avail}"
  fi
  RUNNER_NAME="${base}${suffix}"
  # ---------------------------------------------------------

  SERVICE_NAME="github-runner-$i"

  echo "[INFO] Setting up runner $i in $RUNNER_DIR with name '$RUNNER_NAME'"
  sudo mkdir -p "$RUNNER_DIR"
  sudo chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

  # Stop/disable existing service if present (idempotent)
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    echo "[INFO] Stopping existing service $SERVICE_NAME (if running)"
    sudo systemctl stop "$SERVICE_NAME" || true
    sudo systemctl disable "$SERVICE_NAME" || true
  fi

  # Build flags as a single string (no arrays, POSIX-safe)
  CFG_FLAGS="--url '$REPO_URL' --token '$RUNNER_TOKEN' --name '$RUNNER_NAME' --labels '$RUNNER_LABELS' --unattended --work _work"
  if [ -n "$RUNNER_GROUP" ]; then
    CFG_FLAGS="$CFG_FLAGS --runnergroup '$RUNNER_GROUP'"
  fi
  if [ "$EPHEMERAL" = "true" ]; then
    CFG_FLAGS="$CFG_FLAGS --ephemeral"
  fi

  sudo -u "$RUNNER_USER" bash -lc "
    set -e
    cd \"$RUNNER_DIR\"
    rm -rf ./*
    cp \"$BASE_DIR/$RUNNER_TAR\" .
    tar xzf \"$RUNNER_TAR\"

    # Remove old config if any
    if [ -f \".runner\" ]; then
      yes | ./config.sh remove || true
      rm -f .runner
    fi

    echo \"[INFO] Configuring runner $RUNNER_NAME\"
    eval ./config.sh $CFG_FLAGS
  "

  echo "[INFO] Creating systemd service for $SERVICE_NAME"
  sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOL
[Unit]
Description=GitHub Actions Runner ${i}
After=network.target
StartLimitIntervalSec=0

[Service]
User=${RUNNER_USER}
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
Restart=always
RestartSec=5
KillSignal=SIGTERM
Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1
Environment=DOTNET_NOLOGO=1

[Install]
WantedBy=multi-user.target
EOL

  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SERVICE_NAME"
  echo "[INFO] Runner $i installed and started as $SERVICE_NAME"
done

echo "✅ All ${RUNNER_COUNT} GitHub runners installed and running with labels: ${RUNNER_LABELS}"
[ "$EPHEMERAL" = "true" ] && echo "ℹ️  Ephemeral mode is ON (runners exit after a single job)."