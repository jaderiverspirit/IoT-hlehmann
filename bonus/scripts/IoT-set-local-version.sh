
#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

namespace="gitlab"
gitlab_url="http://gitlab.gitlab.svc.cluster.local:8081"
repo="$gitlab_url/root/iot-gitops.git"

state_dir="${HOME}/.config/iot"
token_file="$state_dir/gitlab-bootstrap-token"
worktree="${HOME}/IoT-GitLab-worktree"

manifest_path="p3/confs/apps/IoT-deployment.yaml"
manifest="$worktree/$manifest_path"

# ============================================================
# 1. Validate command-line arguments
# ============================================================

usage() {
  echo "Usage: $0 v1|v2"
  echo
  echo 'Options:'
  echo '  v1          Deploy playground version 1'
  echo '  v2          Deploy playground version 2'
  echo '  --help, -h  Show this help message'
  echo
  echo 'Changes are committed and pushed to local GitLab.'
  echo 'Argo CD automatically reconciles the Kubernetes deployment.'
}

if [[ $# -eq 1 &&
      ( "$1" == '--help' || "$1" == '-h' ) ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ||
      ( "$1" != 'v1' && "$1" != 'v2' ) ]]; then
  usage >&2
  exit 2
fi

version="$1"
expected_image="wil42/playground:${version}"

# ============================================================
# 2. Verify Kubernetes and GitLab availability
# ============================================================

if [[ "$(kubectl config current-context)" != 'k3d-iot' ]]; then
  echo 'ERROR: Expected Kubernetes context k3d-iot.' >&2
  exit 1
fi

kubectl -n "$namespace" rollout status \
  deployment/iot-gitlab --timeout=120s

# Verify GitLab HTTP connectivity.
if ! curl --noproxy '*' --fail --silent --show-error \
    --connect-timeout 5 --max-time 10 \
    "$gitlab_url/users/sign_in" >/dev/null; then

  echo 'ERROR: Local GitLab is unreachable.' >&2
  echo 'Restore access by running:' >&2
  echo '  ./bonus/scripts/IoT-start-gitlab-access.sh' >&2
  exit 1
fi

# ============================================================
# 3. Verify GitLab authentication
# ============================================================

if [[ ! -r "$token_file" || ! -s "$token_file" ]]; then

  echo 'ERROR: GitLab bootstrap token is missing.' >&2
  echo 'Run:' >&2
  echo '  ./bonus/scripts/IoT-bootstrap-local-repo.sh' >&2
  exit 1
fi

chmod 600 "$token_file"

# Pass the token through standard input rather than
# exposing it in curl command arguments.
if ! token_status="$(
    printf 'PRIVATE-TOKEN: %s\n' "$(cat "$token_file")" |
      curl --noproxy '*' --silent --show-error \
        --connect-timeout 5 --max-time 15 \
        --header @- \
        --output /dev/null \
        --write-out '%{http_code}' \
        "$gitlab_url/api/v4/user"
  )"; then

  echo 'ERROR: GitLab token validation request failed.' >&2
  exit 1
fi

case "$token_status" in
  200)
    echo 'GitLab bootstrap token is valid.'
    ;;

  401)
    echo 'ERROR: GitLab token is invalid or expired.' >&2
    echo 'Regenerate it automatically by running:' >&2
    echo '  ./bonus/scripts/IoT-bootstrap-local-repo.sh' >&2
    exit 1
    ;;

  *)
    printf 'ERROR: Unexpected GitLab API status: %s\n' \
      "$token_status" >&2
    exit 1
    ;;
esac

# Configure Git authentication for this script only.
export GIT_ASKPASS="$root/bonus/scripts/IoT-git-askpass.sh"
export GIT_TERMINAL_PROMPT=0

# ============================================================
# 4. Verify Argo CD source of truth
# ============================================================

app_repo="$(kubectl -n argocd get application iot-gitlab \
  --ignore-not-found \
  -o jsonpath='{.spec.source.repoURL}')"

if [[ "$app_repo" != "$repo" ]]; then

  echo 'ERROR: Argo CD is not configured for local GitLab.' >&2
  echo 'Run:' >&2
  echo '  ./bonus/scripts/IoT-bootstrap-local-repo.sh' >&2
  exit 1
fi

# Prevent two Argo CD Applications from managing
# the same playground Deployment.
github_app="$(kubectl -n argocd get application iot-github \
  --ignore-not-found -o name)"

if [[ -n "$github_app" ]]; then

  echo 'ERROR: GitHub Argo CD Application is still present.' >&2
  echo 'Run IoT-bootstrap-local-repo.sh to switch to GitLab.' >&2
  exit 1
fi

echo 'Argo CD source verified: local GitLab.'

# ============================================================
# 5. Validate the dedicated GitLab working tree
# ============================================================

if [[ -L "$worktree" || ! -d "$worktree/.git" ]]; then

  echo 'ERROR: Valid GitLab working tree not found.' >&2
  echo 'Run IoT-bootstrap-local-repo.sh first.' >&2
  exit 1
fi

if [[ "$(git -C "$worktree" rev-parse --show-toplevel)" \
      != "$worktree" ]]; then

  echo 'ERROR: Unexpected GitLab repository location.' >&2
  exit 1
fi

if [[ "$(git -C "$worktree" branch --show-current)" \
      != 'main' ]]; then

  echo 'ERROR: Expected GitLab working tree branch main.' >&2
  exit 1
fi

if [[ "$(git -C "$worktree" remote get-url origin)" != "$repo" ||
      "$(git -C "$worktree" remote get-url --push origin)" != "$repo" ]]; then

  echo 'ERROR: Unexpected GitLab remote URL.' >&2
  exit 1
fi

# Never overwrite uncommitted changes.
if [[ -n "$(git -C "$worktree" status --porcelain)" ]]; then

  echo 'ERROR: GitLab working tree contains uncommitted changes.' >&2
  echo "Inspect with: git -C \"$worktree\" status" >&2
  exit 1
fi

# ============================================================
# 6. Synchronize Git history safely
# ============================================================

echo 'Fetching current GitLab repository history.'

git -C "$worktree" fetch origin \
  '+refs/heads/main:refs/remotes/origin/main'

local_revision="$(git -C "$worktree" rev-parse HEAD)"
remote_revision="$(git -C "$worktree" rev-parse origin/main)"

if [[ "$local_revision" == "$remote_revision" ]]; then

  echo 'Local and remote Git revisions are synchronized.'

elif git -C "$worktree" merge-base \
    --is-ancestor HEAD origin/main; then

  echo 'Local branch is behind GitLab.'
  echo 'Performing safe fast-forward update.'

  git -C "$worktree" merge --ff-only origin/main

elif git -C "$worktree" merge-base \
    --is-ancestor origin/main HEAD; then

  # Preserve commits from a previously failed Git push.
  # Only allow pending commits affecting the playground manifest.
  if [[ "$(git -C "$worktree" log --format= --name-only \
      origin/main..HEAD | sed '/^$/d' | sort -u)" \
      != "$manifest_path" ]]; then

    echo 'ERROR: Unexpected local unpushed changes.' >&2
    echo 'Inspect local commits before continuing.' >&2
    exit 1
  fi

  echo 'Local playground commits are waiting to be pushed.'
  echo 'Preserving pending commits.'

else

  echo 'ERROR: Local and remote Git histories have diverged.' >&2
  echo 'GitLab may have been reinstalled.' >&2
  echo 'Run the bootstrap script to safely repair the working tree:' >&2
  echo '  ./bonus/scripts/IoT-bootstrap-local-repo.sh' >&2
  exit 1
fi

# ============================================================
# 7. Validate and update the playground manifest
# ============================================================

if [[ ! -f "$manifest" || -L "$manifest" ]]; then

  echo 'ERROR: Playground deployment manifest not found or invalid.' >&2
  exit 1
fi

# Read the current supported playground image.
current_image="$(sed -nE \
  's/^[[:space:]]*image:[[:space:]]*(wil42\/playground:v[12])[[:space:]]*$/\1/p' \
  "$manifest")"

case "$current_image" in
  wil42/playground:v1|wil42/playground:v2)
    ;;

  *)
    echo 'ERROR: Unexpected playground image in manifest.' >&2
    exit 1
    ;;
esac

printf 'Current manifest image: %s\n' "$current_image"
printf 'Requested image: %s\n' "$expected_image"

if [[ "$current_image" == "$expected_image" ]]; then

  echo 'Manifest already specifies the requested version.'

else

  echo 'Updating playground deployment manifest.'

  sed -i -E \
    "s#^([[:space:]]*image:[[:space:]]*wil42/playground:)v[12]([[:space:]]*)\$#\1${version}\2#" \
    "$manifest"

  updated_image="$(sed -nE \
    's/^[[:space:]]*image:[[:space:]]*(wil42\/playground:v[12])[[:space:]]*$/\1/p' \
    "$manifest")"

  if [[ "$updated_image" != "$expected_image" ]]; then

    echo 'ERROR: Manifest image update verification failed.' >&2
    exit 1
  fi

  # Display the manifest change for the evaluation.
  git -C "$worktree" diff -- "$manifest_path"

  git -C "$worktree" add -- "$manifest_path"

  git -C "$worktree" \
    -c user.name='IoT Lab' \
    -c user.email='iot@localhost' \
    commit -m "IoT update playground to ${version}"

fi

# ============================================================
# 8. Push the desired state to local GitLab
# ============================================================

echo 'Pushing desired state to local GitLab.'

# Retry previously failed pushes even when
# no new commit was necessary.
if ! git -C "$worktree" push origin main; then

  echo 'ERROR: GitLab push failed.' >&2
  echo 'Local commits have been preserved.' >&2
  echo 'Resolve the connectivity or authentication issue.' >&2
  echo "Then rerun this script with ${version}." >&2
  exit 1
fi

expected_revision="$(git -C "$worktree" rev-parse HEAD)"

printf 'Expected GitLab revision: %s\n' "$expected_revision"
printf 'Expected playground image: %s\n' "$expected_image"

# ============================================================
# 9. Wait for automatic Argo CD reconciliation
# ============================================================

printf '\nWaiting for Argo CD to deploy %s from local GitLab...\n' \
  "$version"

expected_state="${repo}|${expected_revision}|Synced|Healthy"

for ((attempt=1; attempt<=120; attempt++)); do

  current="$(kubectl -n dev get deployment iot-playground \
    -o jsonpath='{.spec.template.spec.containers[0].image}' \
    2>/dev/null || true)"

  app_state="$(kubectl -n argocd get application iot-gitlab \
    -o jsonpath='{.spec.source.repoURL}{"|"}{.status.sync.revision}{"|"}{.status.sync.status}{"|"}{.status.health.status}' \
    2>/dev/null || true)"

  if [[ "$current" == "$expected_image" &&
        "$app_state" == "$expected_state" ]]; then

    # Wait until Kubernetes finishes the actual rollout.
    kubectl -n dev rollout status \
      deployment/iot-playground --timeout=300s

    echo
    kubectl -n argocd get application iot-gitlab
    echo
    kubectl -n dev get pods -o wide

    echo
    echo '=========================================='
    echo ' GitOps reconciliation completed'
    echo '=========================================='
    printf 'GitLab revision: %s\n' "$expected_revision"
    printf 'Deployed image:  %s\n' "$expected_image"
    echo 'Sync status:     Synced'
    echo 'Health status:   Healthy'
    echo '=========================================='
    echo
    echo 'GitLab -> Argo CD -> Kubernetes'
    echo
    echo 'To verify the application response:'
    echo '  kubectl -n dev port-forward svc/iot-playground 8888:8888'
    echo
    echo 'Then, in another terminal:'
    echo '  curl http://127.0.0.1:8888/'
    echo

    if [[ "$version" == 'v1' ]]; then
      echo 'To deploy v2:'
      echo '  ./bonus/scripts/IoT-set-local-version.sh v2'
    else
      echo 'To restore v1:'
      echo '  ./bonus/scripts/IoT-set-local-version.sh v1'
    fi

    exit 0
  fi

  # Provide periodic feedback during reconciliation.
  if (( attempt % 6 == 0 )); then

    printf 'Still waiting (attempt %s/120).\n' "$attempt"
    printf 'Current deployment image: %s\n' \
      "${current:-unavailable}"
    printf 'Argo CD state: %s\n' \
      "${app_state:-unavailable}"

  fi

  sleep 5
done

# ============================================================
# 10. Report reconciliation failure
# ============================================================

echo 'ERROR: Argo CD reconciliation timed out.' >&2

printf 'Expected revision: %s\n' "$expected_revision" >&2
printf 'Expected image: %s\n' "$expected_image" >&2

echo 'The Git commit has been preserved in GitLab.' >&2

kubectl -n argocd describe application iot-gitlab || true
kubectl -n dev get pods -o wide || true

exit 1
