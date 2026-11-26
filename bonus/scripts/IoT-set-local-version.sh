#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 && ( "$1" == 'v1' || "$1" == 'v2' ) ]] || {
  echo 'Usage: ./bonus/scripts/IoT-set-local-version.sh v1|v2' >&2; exit 2;
}
version="$1"
worktree="${HOME}/IoT-GitLab-worktree"
[[ -d "$worktree/.git" ]] || {
  echo 'Run IoT-bootstrap-local-repo.sh first.' >&2; exit 1;
}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export GIT_ASKPASS="$root/bonus/scripts/IoT-git-askpass.sh"
export GIT_TERMINAL_PROMPT=0

# Verify the expected Kubernetes cluster.
if [[ "$(kubectl config current-context)" != 'k3d-iot' ]]; then
  echo 'ERROR: Expected Kubernetes context k3d-iot.' >&2
  exit 1
fi

# Verify GitLab connectivity before modifying the worktree.
if ! curl --noproxy '*' --fail --silent --show-error \
    --connect-timeout 5 --max-time 10 \
    'http://gitlab.gitlab.svc.cluster.local:8081/users/sign_in' \
    >/dev/null; then
  echo 'ERROR: Local GitLab is unreachable.' >&2
  echo 'Restore access by running:' >&2
  echo '  ./bonus/scripts/IoT-start-gitlab-access.sh' >&2
  exit 1
fi

# Protect the dedicated GitLab worktree.
if [[ -n "$(git -C "$worktree" status --porcelain)" ]]; then
  echo 'ERROR: GitLab worktree contains uncommitted changes.' >&2
  echo "Inspect with: git -C \"$worktree\" status" >&2
  exit 1
fi

if [[ "$(git -C "$worktree" branch --show-current)" != 'main' ]]; then
  echo 'ERROR: Expected GitLab worktree branch main.' >&2
  exit 1
fi

repo='http://gitlab.gitlab.svc.cluster.local:8081/root/iot-gitops.git'
if [[ "$(git -C "$worktree" remote get-url origin)" != "$repo" ||
      "$(git -C "$worktree" remote get-url --push origin)" != "$repo" ]]; then
  echo 'ERROR: Unexpected GitLab remote URL.' >&2
  exit 1
fi

git -C "$worktree" pull --ff-only origin main
manifest="$worktree/p3/confs/apps/IoT-deployment.yaml"
sed -i -E "s#(wil42/playground:)v[12]#\1${version}#" "$manifest"
grep -Fq "image: wil42/playground:${version}" "$manifest"
if ! git -C "$worktree" diff --quiet; then
  git -C "$worktree" add p3/confs/apps/IoT-deployment.yaml
  git -C "$worktree" -c user.name='IoT Lab' -c user.email='iot@localhost' \
	commit -m "IoT update playground to ${version}"
fi

# Retry previously failed pushes even if no new commit is needed.
git -C "$worktree" push origin main

printf 'Waiting for Argo CD to pull image tag %s from local GitLab...\n' "$version"
expected_revision="$(git -C "$worktree" rev-parse HEAD)"

# Autosync polls the repository periodically; test an actual Deployment update.
for attempt in $(seq 1 120); do
  current="$(kubectl -n dev get deploy iot-playground -o \
	jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  revision="$(kubectl -n argocd get application iot-gitlab \
    -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  sync="$(kubectl -n argocd get application iot-gitlab \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kubectl -n argocd get application iot-gitlab \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

  if [[ "$current" == "wil42/playground:${version}" \
     && "$revision" == "$expected_revision" \
     && "$sync" == 'Synced' \
     && "$health" == 'Healthy' ]]; then
	kubectl -n dev rollout status deploy/iot-playground --timeout=300s
	kubectl -n argocd get application iot-gitlab
	kubectl -n dev get pods -o wide
	echo 'GitLab -> Argo CD -> Kubernetes tag reconciliation completed.'
	echo 'To confirm response run: kubectl -n dev port-forward svc/iot-playground 8888:8888'
	echo 'Then: curl http://127.0.0.1:8888/'
	exit 0
  fi
  sleep 5
done
echo 'Timed out: Argo CD did not reconcile GitLab deployment within 10 minutes.' >&2
kubectl -n argocd describe application iot-gitlab || true
exit 1
