#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

namespace="gitlab"
state_dir="${HOME}/.config/iot"
worktree="${HOME}/IoT-GitLab-worktree"

pid_file="$state_dir/gitlab-portforward.pid"
log_file="$state_dir/gitlab-portforward.log"
token_file="$state_dir/gitlab-bootstrap-token"
password_file="$state_dir/gitlab-root-password"

hosts_line='127.0.0.1 gitlab.gitlab.svc.cluster.local # IoT GitLab lab'

# ============================================================
# 1. Command-line arguments
# ============================================================

usage() {
  echo "Usage: $0 --reset|--full"
  echo
  echo 'Options:'
  echo '  --reset     Restore v1 and stop GitLab access.'
  echo '              Preserve GitLab repositories and credentials.'
  echo
  echo '  --full      Remove the Bonus GitLab installation.'
  echo '              Archive the local GitLab working tree.'
  echo '              Remove installation-specific credentials.'
  echo
  echo '  --help, -h  Show this help message.'
  echo
  echo 'The Part 3 K3d cluster and Argo CD installation'
  echo 'are preserved in both modes.'
}

if [[ $# -eq 1 &&
      ( "$1" == '--help' || "$1" == '-h' ) ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ||
      ( "$1" != '--reset' && "$1" != '--full' ) ]]; then
  usage >&2
  exit 2
fi

mode="$1"

# ============================================================
# 2. Verify Kubernetes context
# ============================================================

if [[ "$(kubectl config current-context)" != 'k3d-iot' ]]; then
  echo 'ERROR: Expected Kubernetes context k3d-iot.' >&2
  exit 1
fi

# ============================================================
# 3. Port-forward management
# ============================================================

is_gitlab_forward() {
  local pid="${1:-}"
  local cmd

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  cmd="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1

  [[ "$cmd" == \
    'kubectl -n gitlab port-forward --address 127.0.0.1 svc/gitlab 8081:8081' ]]
}

stop_gitlab_access() {
  local pid

  echo 'Stopping managed GitLab access.'

  if [[ -f "$pid_file" ]]; then

    pid="$(cat "$pid_file")"

    if is_gitlab_forward "$pid"; then

      printf 'Stopping GitLab port-forward PID %s.\n' "$pid"
      kill "$pid"

      for ((attempt=1; attempt<=10; attempt++)); do
        if ! is_gitlab_forward "$pid"; then
          break
        fi

        sleep 1
      done

      if is_gitlab_forward "$pid"; then
        echo 'ERROR: GitLab port-forward did not stop.' >&2
        return 1
      fi

    else

      echo 'No valid managed port-forward found.'

    fi
  fi

  rm -f -- "$pid_file" "$log_file"

  # Do not terminate unrelated processes.
  if [[ -n "$(ss -H -ltn 'sport = :8081')" ]]; then

    echo 'ERROR: Port 8081 is still occupied.' >&2
    echo 'Inspect the listener with:' >&2
    echo "  sudo ss -ltnp 'sport = :8081'" >&2
    return 1

  fi

  echo 'GitLab access stopped.'
}

# ============================================================
# 4. Remove the managed /etc/hosts entry
# ============================================================

remove_hosts_entry() {

  if grep -Fxq "$hosts_line" /etc/hosts; then

    echo 'Removing IoT GitLab entry from /etc/hosts.'

    sudo sed -i \
      '/^127\.0\.0\.1 gitlab\.gitlab\.svc\.cluster\.local # IoT GitLab lab$/d' \
      /etc/hosts

  else

    echo 'No managed GitLab hosts entry found.'

  fi
}

# ============================================================
# 5. Reset mode: restore the demonstration to v1
# ============================================================

if [[ "$mode" == '--reset' ]]; then

  echo 'Restoring the GitLab demonstration to v1.'

  # Ensure GitLab access is available.
  "$root/bonus/scripts/IoT-start-gitlab-access.sh"

  # Restore v1 through GitLab and Argo CD.
  # Never modify the Kubernetes Deployment directly.
  "$root/bonus/scripts/IoT-set-local-version.sh" v1

  # Stop access only after successful reconciliation.
  stop_gitlab_access
  remove_hosts_entry

  echo
  echo '=========================================='
  echo ' GitLab demonstration reset completed'
  echo '=========================================='
  echo 'Application version: v1'
  echo 'GitLab repository:   Preserved'
  echo 'GitLab credentials:  Preserved'
  echo 'Argo CD:             Preserved'
  echo 'K3d cluster:         Preserved'
  echo
  echo 'To start the next demonstration:'
  echo '  ./bonus/scripts/IoT-start-gitlab-access.sh'
  echo '  ./bonus/scripts/IoT-set-local-version.sh v2'

  exit 0
fi

# ============================================================
# 6. Full cleanup confirmation
# ============================================================

echo
echo 'WARNING: Full Bonus cleanup requested.'
echo
echo 'This will remove:'
echo '  - GitLab Argo CD Application'
echo '  - GitLab namespace and its resources'
echo '  - GitLab persistent volume claim'
echo '  - Cached GitLab credentials'
echo '  - Managed GitLab port-forward'
echo '  - Managed GitLab hosts entry'
echo
echo 'GitLab server-side repository data may be permanently lost.'
echo 'The local GitLab working tree will be archived.'
echo
echo 'The K3d cluster, Argo CD installation and main project'
echo 'repository will NOT be deleted.'
echo

if [[ ! -t 0 ]]; then
  echo 'Full cleanup requires an interactive terminal.' >&2
  exit 1
fi

read -rp 'Type DELETE to confirm full cleanup: ' confirmation

if [[ "$confirmation" != 'DELETE' ]]; then
  echo 'Cleanup cancelled. No resources deleted.'
  exit 0
fi

# ============================================================
# 7. Check for unsafe Argo CD deletion
# ============================================================

gitlab_app_finalizers="$(kubectl -n argocd \
  get application iot-gitlab \
  --ignore-not-found \
  -o jsonpath='{.metadata.finalizers}')"

if [[ -n "$gitlab_app_finalizers" &&
      "$gitlab_app_finalizers" != '[]' ]]; then

  echo 'ERROR: GitLab Application has deletion finalizers.' >&2
  echo 'Inspect the Application before deleting it.' >&2
  echo 'Cleanup aborted to protect the playground Deployment.' >&2
  exit 1
fi

# ============================================================
# 8. Stop GitLab access
# ============================================================

stop_gitlab_access
remove_hosts_entry

# ============================================================
# 9. Archive the local GitLab working tree
# ============================================================

if [[ -L "$worktree" ]]; then

  echo 'ERROR: GitLab working tree is a symbolic link.' >&2
  echo 'Inspect it manually before continuing.' >&2
  exit 1

elif [[ -e "$worktree" ]]; then

  if [[ "$(git -C "$worktree" \
      rev-parse --show-toplevel 2>/dev/null)" != "$worktree" ]]; then

    echo 'ERROR: Unexpected GitLab working tree directory.' >&2
    exit 1
  fi

  echo 'Archiving local GitLab working tree.'

  backup_dir="$(mktemp -d \
    "${HOME}/IoT-GitLab-worktree-backup.XXXXXX")"

  mv -- "$worktree" "$backup_dir/worktree"

  printf 'Working tree preserved at: %s\n' \
    "$backup_dir/worktree"

else

  echo 'No local GitLab working tree found.'

fi

# ============================================================
# 10. Remove GitLab Argo CD Application
# ============================================================

echo 'Removing GitLab Argo CD Application.'

kubectl -n argocd delete application iot-gitlab \
  --ignore-not-found \
  --wait=true \
  --timeout=120s

# ============================================================
# 11. Remove GitLab namespace and associated resources
# ============================================================

# Capture the bound volume name for later diagnostics.
gitlab_volume="$(kubectl -n "$namespace" \
  get pvc iot-gitlab-storage \
  --ignore-not-found \
  -o jsonpath='{.spec.volumeName}')"

echo 'Removing GitLab namespace.'

kubectl delete namespace "$namespace" \
  --ignore-not-found \
  --wait=true \
  --timeout=600s

# Check whether the former persistent volume remains.
if [[ -n "$gitlab_volume" ]]; then

  remaining_volume="$(kubectl get pv "$gitlab_volume" \
    --ignore-not-found -o name)"

  if [[ -n "$remaining_volume" ]]; then

    echo 'WARNING: Former GitLab persistent volume still exists.'
    echo "Volume: $gitlab_volume"
    echo 'Inspect its reclaim policy and status before reuse.'

  else

    echo 'Former GitLab persistent volume removed.'

  fi
fi

# ============================================================
# 12. Remove installation-specific cached credentials
# ============================================================

echo 'Removing cached GitLab credentials.'

rm -f -- \
  "$token_file" \
  "$password_file" \
  "$pid_file" \
  "$log_file"

# Remove the state directory only if it is empty.
rmdir "$state_dir" 2>/dev/null || true

# ============================================================
# 13. Verify final cleanup state
# ============================================================

remaining_namespace="$(kubectl get namespace "$namespace" \
  --ignore-not-found -o name)"

remaining_application="$(kubectl -n argocd \
  get application iot-gitlab \
  --ignore-not-found -o name)"

if [[ -n "$remaining_namespace" ||
      -n "$remaining_application" ||
      -e "$worktree" ||
      -e "$token_file" ||
      -e "$password_file" ]]; then

  echo 'ERROR: Bonus cleanup is incomplete.' >&2
  exit 1

fi

echo
echo 'Verifying remaining Kubernetes environment.'

kubectl get nodes
kubectl -n argocd get pods
kubectl -n dev get pods

echo
echo '=========================================='
echo ' Full Bonus cleanup completed'
echo '=========================================='
echo 'GitLab namespace:    Removed'
echo 'GitLab Application:  Removed'
echo 'Cached credentials:  Removed'
echo 'GitLab worktree:     Archived or absent'
echo 'GitLab port-forward: Stopped'
echo 'K3d cluster:         Preserved'
echo 'Argo CD:             Preserved'
echo 'Main repository:     Preserved'
echo
echo 'To perform a fresh Bonus installation:'
echo '  ./bonus/scripts/IoT-install-gitlab.sh'
echo '  ./bonus/scripts/IoT-start-gitlab-access.sh'
echo '  ./bonus/scripts/IoT-bootstrap-local-repo.sh'
