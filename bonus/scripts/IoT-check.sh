
#!/usr/bin/env bash
set -Eeuo pipefail

namespace="gitlab"
gitlab_url="http://gitlab.gitlab.svc.cluster.local:8081"
repo="$gitlab_url/root/iot-gitops.git"

manifest_path="p3/confs/apps/IoT-deployment.yaml"

expected_version=""

# ============================================================
# 1. Command-line arguments
# ============================================================

usage() {
  echo "Usage: $0 [v1|v2]"
  echo
  echo 'Options:'
  echo '  v1          Verify playground version 1'
  echo '  v2          Verify playground version 2'
  echo '  --help, -h  Show this help message'
  echo
  echo 'Without arguments, verify the currently deployed version.'
  echo 'This script performs read-only verification.'
}

if (( $# > 1 )); then
  usage >&2
  exit 2
fi

case "${1:-}" in
  "")
    ;;
  v1|v2)
    expected_version="$1"
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

# ============================================================
# 2. Output helpers
# ============================================================

passed=0

pass() {
  printf '[PASS] %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

section() {
  printf '\n========== %s ==========\n\n' "$1"
}

# ============================================================
# 3. Kubernetes environment
# ============================================================

section 'Kubernetes environment'

[[ "$(kubectl config current-context)" == 'k3d-iot' ]] ||
  fail 'Expected Kubernetes context k3d-iot.'

pass 'Kubernetes context: k3d-iot'

kubectl get nodes

kubectl get namespaces argocd dev gitlab

for ns in argocd dev gitlab; do

  phase="$(kubectl get namespace "$ns" \
    -o jsonpath='{.status.phase}')"

  [[ "$phase" == 'Active' ]] ||
    fail "Namespace $ns is not Active."

  pass "Namespace $ns is Active"

done

# ============================================================
# 4. GitLab installation
# ============================================================

section 'Local GitLab installation'

kubectl -n "$namespace" get deployment,pods,svc,pvc

kubectl -n "$namespace" rollout status \
  deployment/iot-gitlab --timeout=120s ||
  fail 'GitLab deployment is not ready.'

pass 'GitLab deployment is Ready'

storage_status="$(kubectl -n "$namespace" \
  get pvc iot-gitlab-storage \
  -o jsonpath='{.status.phase}')"

[[ "$storage_status" == 'Bound' ]] ||
  fail 'GitLab persistent volume claim is not Bound.'

pass 'GitLab persistent storage is Bound'

service_type="$(kubectl -n "$namespace" get service gitlab \
  -o jsonpath='{.spec.type}')"

[[ "$service_type" == 'ClusterIP' ]] ||
  fail "Unexpected GitLab service type: $service_type"

pass 'GitLab service type: ClusterIP'

# ============================================================
# 5. GitLab repository accessibility
# ============================================================

section 'GitLab repository'

if ! curl --noproxy '*' \
    --fail --silent --show-error \
    --connect-timeout 5 --max-time 15 \
    "$gitlab_url/users/sign_in" >/dev/null; then

  echo 'Run IoT-start-gitlab-access.sh first.' >&2
  fail 'GitLab HTTP endpoint is unreachable.'

fi

pass 'GitLab HTTP endpoint is accessible'

# Verify that the repository can be read without credentials.
# Argo CD uses the publicly readable repository.
public_git() {
  GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS=/bin/false \
  git -c credential.helper= "$@"
}

if ! remote_main="$(public_git ls-remote \
    "$repo" refs/heads/main)"; then

  fail 'Unable to read the GitLab repository anonymously.'

fi

[[ -n "$remote_main" ]] ||
  fail 'GitLab repository has no main branch.'

remote_revision="${remote_main%%$'\t'*}"

printf 'Repository: %s\n' "$repo"
printf 'GitLab main revision: %s\n' "$remote_revision"

pass 'Local GitLab main branch is accessible'

# Read the manifest directly from GitLab.
# No local working tree is modified.
manifest_url="$gitlab_url/root/iot-gitops/-/raw/$remote_revision/$manifest_path"

if ! manifest_content="$(curl --noproxy '*' \
    --fail --silent --show-error \
    --connect-timeout 5 --max-time 15 \
    "$manifest_url")"; then

  fail 'Unable to read the deployment manifest from GitLab.'

fi

desired_image="$(printf '%s\n' "$manifest_content" |
  sed -nE \
    's/^[[:space:]]*image:[[:space:]]*(wil42\/playground:v[12])[[:space:]]*$/\1/p')"

case "$desired_image" in
  wil42/playground:v1|wil42/playground:v2)
    ;;
  *)
    fail 'Unexpected playground image in GitLab manifest.'
    ;;
esac

printf 'GitLab desired image: %s\n' "$desired_image"

pass 'GitLab deployment manifest contains a supported image'

# ============================================================
# 6. Argo CD configuration
# ============================================================

section 'Argo CD configuration'

kubectl -n argocd get application iot-gitlab -o wide

source_url="$(kubectl -n argocd get application iot-gitlab \
  -o jsonpath='{.spec.source.repoURL}')"

[[ "$source_url" == "$repo" ]] ||
  fail "Unexpected Argo CD repository: $source_url"

pass 'Argo CD uses the local GitLab repository'

source_path="$(kubectl -n argocd get application iot-gitlab \
  -o jsonpath='{.spec.source.path}')"

[[ "$source_path" == 'p3/confs/apps' ]] ||
  fail "Unexpected Argo CD source path: $source_path"

pass 'Argo CD uses the Part 3 GitOps manifests'

target_revision="$(kubectl -n argocd get application iot-gitlab \
  -o jsonpath='{.spec.source.targetRevision}')"

case "$target_revision" in
  main|HEAD)
    ;;
  *)
    fail "Unexpected Argo CD target revision: $target_revision"
    ;;
esac

pass "Argo CD tracks revision: $target_revision"

destination_namespace="$(kubectl -n argocd \
  get application iot-gitlab \
  -o jsonpath='{.spec.destination.namespace}')"

[[ "$destination_namespace" == 'dev' ]] ||
  fail "Unexpected destination: $destination_namespace"

pass 'Argo CD destination namespace: dev'

# Verify that automated synchronization is configured.
automated_policy="$(kubectl -n argocd \
  get application iot-gitlab \
  -o jsonpath='{.spec.syncPolicy.automated}')"

automated_enabled="$(kubectl -n argocd \
  get application iot-gitlab \
  -o jsonpath='{.spec.syncPolicy.automated.enabled}')"

[[ -n "$automated_policy" &&
   "$automated_policy" != 'null' &&
   "$automated_enabled" != 'false' ]] ||
  fail 'Argo CD automated synchronization is disabled.'

pass 'Argo CD automated synchronization is enabled'

# Ensure the GitHub Application is not competing with GitLab.
github_application="$(kubectl -n argocd \
  get application iot-github \
  --ignore-not-found -o name)"

[[ -z "$github_application" ]] ||
  fail 'GitHub Application is still present.'

pass 'No conflicting GitHub Argo CD Application'

# ============================================================
# 7. Argo CD synchronization and health
# ============================================================

section 'Argo CD synchronization'

sync_status="$(kubectl -n argocd get application iot-gitlab \
  -o jsonpath='{.status.sync.status}')"

health_status="$(kubectl -n argocd get application iot-gitlab \
  -o jsonpath='{.status.health.status}')"

deployed_revision="$(kubectl -n argocd get application iot-gitlab \
  -o jsonpath='{.status.sync.revision}')"

printf 'Sync status:       %s\n' "$sync_status"
printf 'Health status:     %s\n' "$health_status"
printf 'Deployed revision: %s\n' "$deployed_revision"

[[ "$sync_status" == 'Synced' ]] ||
  fail "Argo CD sync status: $sync_status"

pass 'Argo CD is Synced'

[[ "$health_status" == 'Healthy' ]] ||
  fail "Argo CD health status: $health_status"

pass 'Argo CD is Healthy'

[[ "$deployed_revision" == "$remote_revision" ]] ||
  fail 'Argo CD revision differs from GitLab main.'

pass 'Deployed revision matches GitLab main'

# ============================================================
# 8. Kubernetes application deployment
# ============================================================

section 'Playground deployment'

kubectl -n dev rollout status \
  deployment/iot-playground --timeout=300s ||
  fail 'Playground deployment rollout failed.'

pass 'Playground deployment rollout completed'

kubectl -n dev get deployment,svc,pods -o wide

current_image="$(kubectl -n dev get deployment iot-playground \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"

printf '\nGitLab desired image: %s\n' "$desired_image"
printf 'Kubernetes image:     %s\n' "$current_image"

[[ "$current_image" == "$desired_image" ]] ||
  fail 'Kubernetes image differs from GitLab desired state.'

pass 'Kubernetes image matches the GitLab manifest'

if [[ -n "$expected_version" ]]; then

  [[ "$current_image" == "wil42/playground:$expected_version" ]] ||
    fail "Expected playground $expected_version."

  pass "Requested playground version: $expected_version"

fi

current_version="${current_image##*:}"

# ============================================================
# 9. Final verification summary
# ============================================================

echo
echo '=========================================='
echo ' BONUS INFRASTRUCTURE CHECK PASSED'
echo '=========================================='
printf 'Checks passed:   %s\n' "$passed"
echo 'Kubernetes:      k3d-iot'
echo 'GitLab:          Ready'
echo 'Storage:         Bound'
echo 'Repository:      Local GitLab'
echo 'Auto-sync:       Enabled'
printf 'Sync status:     %s\n' "$sync_status"
printf 'Health status:   %s\n' "$health_status"
printf 'GitLab revision: %s\n' "$remote_revision"
printf 'Image:           %s\n' "$current_image"
printf 'Version:         %s\n' "$current_version"
echo '=========================================='

echo
echo 'GitLab -> Argo CD -> Kubernetes'
echo
echo 'Verify the application HTTP response manually:'
echo
echo '  kubectl -n dev port-forward svc/iot-playground 8888:8888'
echo
echo 'In another terminal:'
echo
echo '  curl http://127.0.0.1:8888/'
echo
printf 'Expected HTTP response: %s\n' "$current_version"

echo
echo 'Stop the playground port-forward with Ctrl+C.'
echo

if [[ "$current_version" == 'v1' ]]; then
  echo 'Next: ./bonus/scripts/IoT-set-local-version.sh v2'
else
  echo 'Next: ./bonus/scripts/IoT-set-local-version.sh v1'
fi
