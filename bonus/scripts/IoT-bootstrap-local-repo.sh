#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
state_dir="${HOME}/.config/iot"
mkdir -p "$state_dir"
chmod 700 "$state_dir"

kubectl config current-context | grep -qx k3d-iot
kubectl -n gitlab rollout status deploy/iot-gitlab --timeout=120s
curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 15 \
  http://gitlab.gitlab.svc.cluster.local:8081/users/sign_in >/dev/null || {
	echo 'GitLab access unavailable. Run IoT-start-gitlab-access.sh.' >&2; exit 1;
  }

# Generate a personal access token with GitLab's own Rails API. Do not reuse a
# password, put a secret in the repository, or request GitHub credentials.
token_file="$state_dir/gitlab-bootstrap-token"
if [[ ! -s "$token_file" ]]; then
  (umask 077; openssl rand -hex 10 > "$token_file")
  token="$(cat "$token_file")"
  # Rails runner loads the Ruby script through standard input in a temporary
  # container file. This is a local single-node lab with cluster-admin access.
  kubectl -n gitlab exec -i deployment/iot-gitlab -- \
	env "IOT_GITLAB_PAT=$token" bash -c \
	'cat >/tmp/iot-bootstrap.rb && gitlab-rails runner /tmp/iot-bootstrap.rb; rc=$?; rm -f /tmp/iot-bootstrap.rb; exit "$rc"' \
	< "$root/bonus/scripts/IoT-bootstrap-rails.rb" || {
	  rm -f "$token_file"
	  echo 'Could not bootstrap GitLab token; inspect the gitlab pod logs.' >&2
	  exit 1
	}
fi

api='http://gitlab.gitlab.svc.cluster.local:8081/api/v4'
auth=(-H "PRIVATE-TOKEN: $(cat "$token_file")")
if ! curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 15 "${auth[@]}" \
	"$api/user" > /dev/null; then
  echo 'Bootstrap token rejected or expired; remove ~/.config/iot/gitlab-bootstrap-token and rerun.' >&2
  exit 1
fi

# A publicly readable project is sufficient for Argo CD: it has no push token.
# Write credentials are required only for the VM user's git push.
if ! project_status="$(curl --noproxy '*' \
    --silent --show-error \
    --connect-timeout 5 --max-time 15 \
    --output /dev/null --write-out '%{http_code}' \
    "${auth[@]}" "$api/projects/root%2Fiot-gitops")"; then
  echo 'ERROR: GitLab project lookup failed.' >&2
  exit 1
fi

case "$project_status" in
  200)
    echo 'Existing GitLab project detected.'
    ;;
  404)
    echo 'Creating local GitLab project.'
    curl --noproxy '*' --fail --silent --show-error \
      --connect-timeout 5 --max-time 15 "${auth[@]}" \
      --request POST --data-urlencode 'name=IoT-GitOps' \
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

repo='http://gitlab.gitlab.svc.cluster.local:8081/root/iot-gitops.git'
export GIT_ASKPASS="$root/bonus/scripts/IoT-git-askpass.sh"
export GIT_TERMINAL_PROMPT=0

# Seed the local GitLab repository with the *same GitOps manifests* as P3.
# Use a separate temp git repo: NEVER alter the 42 repository's git remote.
seed="$(mktemp -d)"
trap 'rm -rf "$seed"' EXIT
mkdir -p "$seed/p3/confs"
cp -a "$root/p3/confs/apps" "$seed/p3/confs/apps"
# Reset the *seed copy* to v1 even if P3's GitHub demonstration ended on v2.
# This ensures the bonus can independently demonstrate v1 -> v2 via GitLab.
sed -i -E 's#(wil42/playground:)v[12]#\1v1#' \
  "$seed/p3/confs/apps/IoT-deployment.yaml"
git -C "$seed" init -b main -q
git -C "$seed" add p3/confs/apps
git -C "$seed" -c user.name='IoT Lab' -c user.email='iot@localhost' \
  commit -m 'IoT initial GitOps manifests v1' -q
git -C "$seed" remote add origin "$repo"
# A repeated bootstrap does not overwrite prior GitLab changes.
# Distinguish repository access failure from an empty branch.
if ! remote_main="$(git ls-remote "$repo" refs/heads/main)"; then
  echo 'ERROR: Unable to read the local GitLab repository.' >&2
  echo 'Verify GitLab connectivity and authentication.' >&2
  exit 1
fi

if [[ -z "$remote_main" ]]; then
  echo 'Initializing GitLab main branch with v1 manifests.'
  git -C "$seed" push -u origin main
else
  echo 'Existing GitLab main branch detected. Preserving history.'
fi

worktree="${HOME}/IoT-GitLab-worktree"
if [[ ! -e "$worktree" ]]; then
  git clone --branch main "$repo" "$worktree"
else
  if [[ "$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null)" != "$worktree" ]]; then
    echo 'ERROR: Existing GitLab worktree is not a valid standalone repository.' >&2
    exit 1
  fi

  if [[ "$(git -C "$worktree" remote get-url origin)" != "$repo" ||
        "$(git -C "$worktree" remote get-url --push origin)" != "$repo" ]]; then
    echo 'ERROR: GitLab worktree has an unexpected remote URL.' >&2
    exit 1
  fi

  if [[ "$(git -C "$worktree" branch --show-current)" != 'main' ]]; then
    echo 'ERROR: GitLab worktree must be on branch main.' >&2
    exit 1
  fi

  if [[ -n "$(git -C "$worktree" status --porcelain)" ]]; then
    echo 'ERROR: GitLab worktree contains uncommitted changes.' >&2
    exit 1
  fi

  echo 'Existing GitLab worktree validated.'
fi

# Read the desired state directly from the local GitLab repository.
git -C "$seed" fetch --quiet origin main

expected_revision="$(git -C "$seed" rev-parse FETCH_HEAD)"

expected_image="$(git -C "$seed" show \
  "${expected_revision}:p3/confs/apps/IoT-deployment.yaml" \
  | sed -nE 's/^[[:space:]]*image:[[:space:]]*(wil42\/playground:v[12])[[:space:]]*$/\1/p')"

case "$expected_image" in
  wil42/playground:v1|wil42/playground:v2) ;;
  *)
    echo 'ERROR: Invalid playground image in GitLab manifest.' >&2
    exit 1
    ;;
esac

expected_version="${expected_image##*:}"

printf 'Expected GitLab revision: %s\n' "$expected_revision"
printf 'Expected playground image: %s\n' "$expected_image"

# Avoid two Argo Applications fighting over the same Deployment: the bonus
# replaces the GitHub app as the source of truth; it does not delete dev Pods.
# Protect managed resources against cascading Application deletion.
github_finalizers="$(kubectl -n argocd get application iot-github \
  --ignore-not-found \
  -o jsonpath='{.metadata.finalizers}')"

if [[ -n "$github_finalizers" && "$github_finalizers" != '[]' ]]; then
  echo 'ERROR: GitHub Application has deletion finalizers.' >&2
  echo 'Inspect the Application before switching to GitLab.' >&2
  exit 1
fi

kubectl -n argocd delete application iot-github \
  --ignore-not-found --wait=true --timeout=60s
kubectl apply -f "$root/bonus/confs/IoT-argocd-gitlab-application.yaml"
printf '\nGitLab repo: %s\n' "$repo"
printf 'Working tree: %s\n' "$worktree"
printf 'Argo CD Application: iot-gitlab\n'
printf 'Waiting for GitLab %s manifests to reconcile...\n' "$expected_version"

for attempt in $(seq 1 120); do
  current="$(kubectl -n dev get deployment iot-playground \
    -o jsonpath='{.spec.template.spec.containers[0].image}' \
    2>/dev/null || true)"

  app_state="$(kubectl -n argocd get application iot-gitlab \
    -o jsonpath='{.spec.source.repoURL}{"|"}{.status.sync.revision}{"|"}{.status.sync.status}{"|"}{.status.health.status}' \
    2>/dev/null || true)"

  expected_state="${repo}|${expected_revision}|Synced|Healthy"

  if [[ "$current" == "$expected_image" &&
        "$app_state" == "$expected_state" ]]; then

    kubectl -n dev rollout status deployment/iot-playground --timeout=300s
    kubectl -n argocd get application iot-gitlab

    printf 'GitLab %s deployed and Ready.\n' "$expected_version"
    printf 'Verified GitLab revision: %s\n' "$expected_revision"

    if [[ "$expected_version" == 'v1' ]]; then
      next_version='v2'
    else
      next_version='v1'
    fi

    printf 'Next: ./bonus/scripts/IoT-set-local-version.sh %s\n' "$next_version"
    exit 0
  fi

  sleep 5
done

echo 'ERROR: Local GitLab deployment failed to reconcile with Argo CD.' >&2
printf 'Expected revision: %s\n' "$expected_revision" >&2
printf 'Expected image: %s\n' "$expected_image" >&2
kubectl -n argocd describe application iot-gitlab || true
exit 1
