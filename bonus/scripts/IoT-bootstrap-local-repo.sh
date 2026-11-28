
#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

namespace="gitlab"
gitlab_url="http://gitlab.gitlab.svc.cluster.local:8081"
api="$gitlab_url/api/v4"
repo="$gitlab_url/root/iot-gitops.git"

state_dir="${HOME}/.config/iot"
token_file="$state_dir/gitlab-bootstrap-token"
worktree="${HOME}/IoT-GitLab-worktree"

# Protect credentials and temporary files.
umask 077
mkdir -p "$state_dir"
chmod 700 "$state_dir"

# Verify Kubernetes context.
kubectl config current-context | grep -qx 'k3d-iot' || {
  echo 'Expected Kubernetes context k3d-iot.' >&2
  exit 1
}

# Verify GitLab deployment.
kubectl -n "$namespace" rollout status \
  deployment/iot-gitlab --timeout=120s

# Verify GitLab HTTP access.
curl --noproxy '*' --fail --silent --show-error \
  --connect-timeout 5 --max-time 15 \
  "$gitlab_url/users/sign_in" >/dev/null || {
    echo 'GitLab access unavailable.' >&2
    echo 'Run IoT-start-gitlab-access.sh first.' >&2
    exit 1
}

# Clean up temporary resources when the script exits.
seed=""
replacement=""
token_tmp=""

cleanup() {
  if [[ -n "$seed" ]]; then
    rm -rf -- "$seed"
  fi

  if [[ -n "$replacement" ]]; then
    rm -rf -- "$replacement"
  fi

  if [[ -n "$token_tmp" ]]; then
    rm -f -- "$token_tmp"
  fi
}

trap cleanup EXIT

# ============================================================
# 1. GitLab authentication
# ============================================================

# Pass the authentication header through standard input
# instead of exposing the token in curl command arguments.
gitlab_api() {
  printf 'PRIVATE-TOKEN: %s\n' "$token" |
    curl --noproxy '*' --silent --show-error \
      --connect-timeout 5 --max-time 15 \
      --header @- "$@"
}

# Return the HTTP status of the authentication request.
validate_token() {
  gitlab_api \
    --output /dev/null \
    --write-out '%{http_code}' \
    "$api/user"
}

# Generate a new personal access token through GitLab Rails.
generate_token() {
  local candidate
  local status

  echo 'Generating GitLab bootstrap token.'

  candidate="$(openssl rand -hex 10)"

  # Pass both the token and Ruby script through standard input.
  # The token is not included in kubectl command arguments.
  if ! {
    printf '%s\n' "$candidate"
    cat "$root/bonus/scripts/IoT-bootstrap-rails.rb"
  } | kubectl -n "$namespace" exec -i \
      deployment/iot-gitlab -- bash -c '
        set -Eeuo pipefail
        umask 077

        IFS= read -r IOT_GITLAB_PAT
        export IOT_GITLAB_PAT

        script="$(mktemp /tmp/iot-bootstrap.XXXXXX.rb)"
        trap "rm -f -- \"$script\"" EXIT

        cat > "$script"
        gitlab-rails runner "$script"
      '; then

    echo 'ERROR: Could not bootstrap GitLab token.' >&2
    echo 'Inspect the GitLab pod logs.' >&2
    return 1
  fi

  token="$candidate"
  unset candidate

  # Verify the generated token before storing it.
  if ! status="$(validate_token)"; then
    echo 'ERROR: Token validation request failed.' >&2
    return 1
  fi

  if [[ "$status" != '200' ]]; then
    printf 'ERROR: New token rejected (HTTP %s).\n' \
      "$status" >&2
    return 1
  fi

  # Store the validated token securely and atomically.
  token_tmp="$(mktemp "$state_dir/gitlab-token.XXXXXX")"

  printf '%s' "$token" > "$token_tmp"
  chmod 600 "$token_tmp"

  mv -f -- "$token_tmp" "$token_file"
  token_tmp=""

  echo 'GitLab bootstrap token created and validated.'
}

# Reuse a cached token only if GitLab accepts it.
token=""

if [[ -s "$token_file" ]]; then

  chmod 600 "$token_file"
  token="$(cat "$token_file")"

  echo 'Validating existing GitLab bootstrap token.'

  if ! token_status="$(validate_token)"; then
    echo 'ERROR: Unable to validate GitLab token.' >&2
    echo 'Check GitLab connectivity.' >&2
    exit 1
  fi

  case "$token_status" in
    200)
      echo 'Existing GitLab bootstrap token is valid.'
      ;;

    401)
      echo 'Cached token rejected or expired.'
      echo 'Automatically generating a replacement.'
      generate_token
      ;;

    *)
      printf 'ERROR: Unexpected authentication status: %s\n' \
        "$token_status" >&2
      exit 1
      ;;
  esac

else
  generate_token
fi

# ============================================================
# 2. Create or reuse the local GitLab project
# ============================================================

# A publicly readable project is sufficient for Argo CD.
# Write credentials are required only for Git pushes.

if ! project_status="$(gitlab_api \
    --output /dev/null \
    --write-out '%{http_code}' \
    "$api/projects/root%2Fiot-gitops")"; then

  echo 'ERROR: GitLab project lookup failed.' >&2
  exit 1
fi

case "$project_status" in
  200)
    echo 'Existing GitLab project detected.'
    ;;

  404)
    echo 'Creating local GitLab project.'

    gitlab_api --fail \
      --request POST \
      --data-urlencode 'name=IoT-GitOps' \
      --data-urlencode 'path=iot-gitops' \
      --data-urlencode 'visibility=public' \
      "$api/projects" >/dev/null
    ;;

  *)
    printf 'ERROR: Unexpected GitLab API status: %s\n' \
      "$project_status" >&2
    exit 1
    ;;
esac

# Configure Git authentication for this script only.
export GIT_ASKPASS="$root/bonus/scripts/IoT-git-askpass.sh"
export GIT_TERMINAL_PROMPT=0

# ============================================================
# 3. Initialize the GitLab repository
# ============================================================

# Use a separate temporary repository.
# Never modify the main 42 project repository or its remote.
seed="$(mktemp -d)"

git -C "$seed" init -b main -q
git -C "$seed" remote add origin "$repo"

# Distinguish an empty repository from an access failure.
if ! remote_main="$(git ls-remote "$repo" refs/heads/main)"; then

  echo 'ERROR: Unable to read the GitLab repository.' >&2
  echo 'Verify GitLab connectivity and authentication.' >&2
  exit 1
fi

if [[ -z "$remote_main" ]]; then

  echo 'Initializing GitLab main branch with v1 manifests.'

  mkdir -p "$seed/p3/confs"

  cp -a "$root/p3/confs/apps" \
    "$seed/p3/confs/apps"

  # Reset only the seed copy to v1.
  # The original Part 3 manifests remain untouched.
  sed -i -E 's#(wil42/playground:)v[12]#\1v1#' \
    "$seed/p3/confs/apps/IoT-deployment.yaml"

  git -C "$seed" add p3/confs/apps

  git -C "$seed" \
    -c user.name='IoT Lab' \
    -c user.email='iot@localhost' \
    commit -m 'IoT initial GitOps manifests v1' -q

  git -C "$seed" push -u origin main

else

  echo 'Existing GitLab main branch detected.'
  echo 'Preserving remote Git history.'

fi

# ============================================================
# 4. Validate and synchronize the local GitLab working tree
# ============================================================

if [[ -L "$worktree" ]]; then

  echo 'ERROR: GitLab worktree must not be a symbolic link.' >&2
  exit 1

elif [[ ! -e "$worktree" ]]; then

  echo 'Cloning GitLab repository.'
  git clone --branch main "$repo" "$worktree"

else

  echo 'Validating existing GitLab working tree.'

  # Ensure this is a standalone Git repository.
  if [[ "$(git -C "$worktree" \
      rev-parse --show-toplevel 2>/dev/null)" != "$worktree" ]]; then

    echo 'ERROR: Existing GitLab worktree is not a valid repository.' >&2
    exit 1
  fi

  # Verify fetch and push destinations.
  if [[ "$(git -C "$worktree" remote get-url origin)" != "$repo" ||
        "$(git -C "$worktree" remote get-url --push origin)" != "$repo" ]]; then

    echo 'ERROR: GitLab worktree has an unexpected remote URL.' >&2
    exit 1
  fi

  # Verify current branch.
  if [[ "$(git -C "$worktree" branch --show-current)" != 'main' ]]; then

    echo 'ERROR: GitLab worktree must be on branch main.' >&2
    exit 1
  fi

  # Never overwrite uncommitted changes.
  if [[ -n "$(git -C "$worktree" status --porcelain)" ]]; then

    echo 'ERROR: GitLab worktree contains uncommitted changes.' >&2
    echo 'Commit or back up these changes before continuing.' >&2
    exit 1
  fi

  # Update remote-tracking history.
  # This does not modify the local main branch.
  git -C "$worktree" fetch origin \
    '+refs/heads/main:refs/remotes/origin/main'

  local_revision="$(git -C "$worktree" rev-parse HEAD)"

  remote_revision="$(git -C "$worktree" rev-parse origin/main)"

  if [[ "$local_revision" == "$remote_revision" ]]; then

    echo 'GitLab working tree is already synchronized.'

  elif git -C "$worktree" merge-base \
      --is-ancestor HEAD origin/main; then

    echo 'Local working tree is behind GitLab.'
    echo 'Performing a safe fast-forward update.'

    git -C "$worktree" merge --ff-only origin/main

  elif git -C "$worktree" merge-base \
      --is-ancestor origin/main HEAD; then

    echo 'ERROR: Local working tree contains unpushed commits.' >&2
    echo 'Preserving local Git history.' >&2
    echo 'Inspect the commits with:' >&2
    echo "  git -C \"$worktree\" log origin/main..HEAD --oneline" >&2

    exit 1

  else

    # Histories diverged or belong to different installations.
    # Do not merge unrelated histories or discard old commits.
    echo 'GitLab working tree has incompatible Git history.'
    echo 'Preparing a fresh clone of the current repository.'

    replacement="$(mktemp -d \
      "${HOME}/IoT-GitLab-replacement.XXXXXX")"

    # Clone first, so a failed clone cannot destroy the old tree.
    git clone --branch main "$repo" "$replacement/worktree"

    # Preserve the complete previous repository.
    backup_dir="$(mktemp -d \
      "${HOME}/IoT-GitLab-worktree-backup.XXXXXX")"

    mv -- "$worktree" "$backup_dir/worktree"

    # Activate the newly cloned repository.
    if ! mv -- "$replacement/worktree" "$worktree"; then

      echo 'ERROR: Could not activate the new working tree.' >&2

      if mv -- "$backup_dir/worktree" "$worktree"; then
        echo 'Previous working tree restored.' >&2
      else
        echo "Previous working tree preserved at $backup_dir" >&2
      fi

      exit 1
    fi

    printf 'Previous working tree backed up to: %s\n' \
      "$backup_dir/worktree"

    echo 'New GitLab working tree synchronized successfully.'

  fi
fi

# Verify final local and remote alignment.
local_revision="$(git -C "$worktree" rev-parse HEAD)"
remote_revision="$(git -C "$worktree" rev-parse origin/main)"

if [[ "$local_revision" != "$remote_revision" ]]; then

  echo 'ERROR: GitLab working tree is not synchronized.' >&2
  exit 1
fi

echo 'GitLab working tree validated and synchronized.'

# ============================================================
# 5. Determine the desired GitOps state
# ============================================================

# Read desired state directly from the local GitLab repository.
git -C "$seed" fetch --quiet origin main

expected_revision="$(git -C "$seed" rev-parse FETCH_HEAD)"

expected_image="$(git -C "$seed" show \
  "${expected_revision}:p3/confs/apps/IoT-deployment.yaml" |
  sed -nE \
    's/^[[:space:]]*image:[[:space:]]*(wil42\/playground:v[12])[[:space:]]*$/\1/p')"

case "$expected_image" in
  wil42/playground:v1|wil42/playground:v2)
    ;;

  *)
    echo 'ERROR: Invalid playground image in GitLab manifest.' >&2
    exit 1
    ;;
esac

expected_version="${expected_image##*:}"

printf 'Expected GitLab revision: %s\n' "$expected_revision"
printf 'Expected playground image: %s\n' "$expected_image"

# ============================================================
# 6. Switch Argo CD from GitHub to local GitLab
# ============================================================

# Avoid two Applications managing the same Deployment.
# Protect existing workloads from cascading deletion.

github_finalizers="$(kubectl -n argocd get application iot-github \
  --ignore-not-found \
  -o jsonpath='{.metadata.finalizers}')"

if [[ -n "$github_finalizers" && "$github_finalizers" != '[]' ]]; then

  echo 'ERROR: GitHub Application has deletion finalizers.' >&2
  echo 'Inspect the Application before switching to GitLab.' >&2
  exit 1
fi

kubectl -n argocd delete application iot-github \
  --ignore-not-found \
  --wait=true \
  --timeout=60s

kubectl apply -f \
  "$root/bonus/confs/IoT-argocd-gitlab-application.yaml"

printf '\nGitLab repo: %s\n' "$repo"
printf 'Working tree: %s\n' "$worktree"
printf 'Argo CD Application: iot-gitlab\n'

printf 'Waiting for GitLab %s manifests to reconcile...\n' \
  "$expected_version"

# ============================================================
# 7. Verify GitOps reconciliation
# ============================================================

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

    kubectl -n dev rollout status \
      deployment/iot-playground --timeout=300s

    kubectl -n argocd get application iot-gitlab

    printf '\nGitLab %s deployed and Ready.\n' \
      "$expected_version"

    printf 'Verified GitLab revision: %s\n' \
      "$expected_revision"

    if [[ "$expected_version" == 'v1' ]]; then
      next_version='v2'
    else
      next_version='v1'
    fi

    echo 'GitLab bootstrap completed successfully.'

    printf 'Next: ./bonus/scripts/IoT-set-local-version.sh %s\n' \
      "$next_version"

    exit 0
  fi

  sleep 5
done

# Reconciliation timeout.
echo 'ERROR: Local GitLab deployment failed to reconcile with Argo CD.' >&2

printf 'Expected revision: %s\n' "$expected_revision" >&2
printf 'Expected image: %s\n' "$expected_image" >&2

kubectl -n argocd describe application iot-gitlab || true

exit 1
