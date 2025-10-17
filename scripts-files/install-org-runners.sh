# === paste everything from here ===
ORG_URL="https://github.com/wesley-mbarga-LLC"   # ✅ correct org URL
TOKEN="BBJ7MO6L5BMCQZHHTI6M3XTI6K6FO"            # 🔑 fresh org registration token
RUN_AS_USER="mac"
BASE_DIR="/opt/github-org-runners"

fix_runner () {
  name="$1"; labels="$2"; dir="${BASE_DIR}/${name}"
  echo "=== Fixing runner: $name ==="
  sudo mkdir -p "$dir"
  sudo chown -R "$RUN_AS_USER:$RUN_AS_USER" "$dir"

  # Stop service if it exists (ignore errors)
  sudo bash -lc "cd '$dir' 2>/dev/null && ./svc.sh stop || true"

  # Re-register at org scope (NO sudo)
  sudo -u "$RUN_AS_USER" -H bash -lc "
    cd '$dir' || exit 1
    # If runner files aren't present yet, download latest
    if [ ! -d bin ]; then
      ver=\$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | sed -n 's/.*\"tag_name\":[[:space:]]*\"\(v[0-9.]*\)\".*/\1/p' | head -n1)
      [ -z \"\$ver\" ] && ver='v2.321.0'
      tarball=\"actions-runner-linux-x64-\${ver#v}.tar.gz\"
      curl -fsSLO \"https://github.com/actions/runner/releases/download/\$ver/\$tarball\"
      tar xzf \"\$tarball\"
    fi
    ./config.sh remove --token '$TOKEN' || true
    ./config.sh --url '$ORG_URL' --token '$TOKEN' \
      --name '$name' --labels '$labels' \
      --unattended --replace
  "

  # Install & start systemd service
  sudo bash -lc "cd '$dir' && ./svc.sh install"
  sudo bash -lc "cd '$dir' && ./svc.sh start"

  echo
}

# Allow user to talk to Docker (harmless if already set)
if getent group docker >/dev/null 2>&1; then
  sudo usermod -aG docker "$RUN_AS_USER" || true
  sudo systemctl restart docker || true
fi

fix_runner build  "self-hosted,linux,build"
fix_runner test   "self-hosted,linux,test"
fix_runner deploy "self-hosted,linux,deploy"

echo "✅ Done. Current statuses:"
systemctl --no-pager status 'actions.runner.*build*' 'actions.runner.*test*' 'actions.runner.*deploy*' || true
echo "🔎 Now check: https://github.com/orgs/wesley-mbarga-LLC/settings/actions/runners"
# === to here ===
