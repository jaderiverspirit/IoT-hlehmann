
#!/usr/bin/env bash
set -Eeuo pipefail

# Execute from the same Linux VM running K3d Part 3.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

namespace="gitlab"
secret_name="iot-gitlab-bootstrap"
secret_dir="${HOME}/.config/iot"
secret_file="$secret_dir/gitlab-root-password"
token_file="$secret_dir/gitlab-bootstrap-token"

# Verify Kubernetes context.
kubectl config current-context | grep -qx 'k3d-iot' || {
  echo 'Expected Kubernetes context k3d-iot, run Part 3 first.' >&2
  exit 1
}

# Verify Part 3 prerequisites.
kubectl get namespace argocd >/dev/null || {
  echo 'Argo CD must be installed first (Part 3).' >&2
  exit 1
}

# Protect locally stored credentials.
umask 077
mkdir -p "$secret_dir"
chmod 700 "$secret_dir"

# Distinguish fresh installation from existing installation.
fresh_install=false

if [[ -z "$(kubectl get namespace "$namespace" \
    --ignore-not-found -o name)" ]]; then

  fresh_install=true
  echo 'Fresh GitLab installation detected.'

  # Generate credentials for this installation.
  openssl rand -hex 32 > "$secret_file"

  # Invalidate the token from the previous installation.
  rm -f "$token_file"

  kubectl create namespace "$namespace"

else

  echo 'Existing GitLab namespace detected.'

  # Preserve credentials belonging to the existing installation.
  if kubectl -n "$namespace" get secret "$secret_name" >/dev/null 2>&1; then

    kubectl -n "$namespace" get secret "$secret_name" \
      -o jsonpath='{.data.root-password}' |
      base64 --decode > "$secret_file"

    if [[ ! -s "$secret_file" ]]; then
      echo 'GitLab bootstrap password is empty.' >&2
      exit 1
    fi

  else

    echo 'Existing namespace has no bootstrap Secret.' >&2
    echo 'Inspect the existing installation before continuing.' >&2
    exit 1

  fi
fi

chmod 600 "$secret_file"

# Create or reconcile the Kubernetes Secret.
kubectl -n "$namespace" create secret generic "$secret_name" \
  --from-file="root-password=${secret_file}" \
  --dry-run=client -o yaml |
  kubectl apply -f -

# Deploy GitLab using the existing declarative manifest.
kubectl apply -f "$root/bonus/confs/IoT-gitlab.yaml"

# Wait for GitLab to become ready.
echo 'Waiting for local GitLab to become ready.'
echo 'Initial migration can take time.'

kubectl -n "$namespace" rollout status \
  deployment/iot-gitlab --timeout=1800s

# Verify the initial root password on fresh installations.
if [[ "$fresh_install" == true ]]; then

  echo 'Verifying GitLab root credentials.'

  kubectl -n "$namespace" exec -i deployment/iot-gitlab -- \
    gitlab-rails runner '
      password = STDIN.read.strip
      user = User.find_by!(username: "root")

      unless user.valid_password?(password)
        user.password = password
        user.password_confirmation = password
        user.password_automatically_set = false
        user.save!
      end

      abort "Root password verification failed." unless
        user.reload.valid_password?(password)

      puts "GitLab root password verified successfully."
    ' < "$secret_file"

else

  echo 'Existing GitLab administrator password left unchanged.'

fi

# Display installation status.
kubectl -n "$namespace" get pod,service,pvc

echo
echo '=========================================='
echo ' GitLab installation completed successfully'
echo '=========================================='
echo
echo 'Next: ./bonus/scripts/IoT-start-gitlab-access.sh'
echo 'Then: ./bonus/scripts/IoT-bootstrap-local-repo.sh'
