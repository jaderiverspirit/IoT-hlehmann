
#!/usr/bin/env bash
set -Eeuo pipefail

namespace="gitlab"
gitlab_url="http://gitlab.gitlab.svc.cluster.local:8081"
state_dir="${HOME}/.config/iot"
secret_file="$state_dir/gitlab-root-password"
pid_file="$state_dir/gitlab-portforward.pid"
log_file="$state_dir/gitlab-portforward.log"

change_password=false

# Parse command-line arguments.
if (( $# > 1 )); then
  echo 'Only one option is supported.' >&2
  exit 1
fi

case "${1:-}" in
  "")
    ;;
  --change-password)
    change_password=true
    ;;
  --help|-h)
    echo "Usage: $0 [OPTION]"
    echo
    echo "Options:"
    echo "  --change-password  Change GitLab root password"
    echo "  --help, -h         Show this help message"
    echo
    echo "Without options, configure GitLab access"
    echo "and verify existing administrator credentials."
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    exit 1
    ;;
esac

# Verify Kubernetes context.
kubectl config current-context | grep -qx 'k3d-iot' || {
  echo 'Expected Kubernetes context k3d-iot.' >&2
  exit 1
}

# Verify GitLab service and deployment.
kubectl -n "$namespace" get service gitlab >/dev/null

kubectl -n "$namespace" rollout status \
  deployment/iot-gitlab --timeout=120s

# Protect local state and credentials.
umask 077
mkdir -p "$state_dir"
chmod 700 "$state_dir"

# Access the same GitLab URL from inside the cluster
# and from the Linux VM.
# Inside: native Kubernetes DNS.
# Outside: loopback and kubectl port-forward.
line='127.0.0.1 gitlab.gitlab.svc.cluster.local # IoT GitLab lab'

if ! grep -Fxq "$line" /etc/hosts; then
  printf '%s\n' "$line" | sudo tee -a /etc/hosts >/dev/null
fi

# Check whether GitLab is reachable through HTTP.
gitlab_reachable() {
  curl --noproxy '*' --silent --fail \
    --connect-timeout 3 --max-time 5 \
    "$gitlab_url/users/sign_in" >/dev/null
}

# Verify that a PID belongs to our GitLab port-forward.
is_gitlab_forward() {
  local pid="${1:-}"
  local cmd

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  cmd="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1

  [[ "$cmd" == \
    'kubectl -n gitlab port-forward --address 127.0.0.1 svc/gitlab 8081:8081' ]]
}

# Recover an unresponsive managed port-forward.
if [[ -f "$pid_file" ]] &&
    is_gitlab_forward "$(cat "$pid_file")"; then

  if ! gitlab_reachable; then

    echo 'Restarting unresponsive GitLab port-forward.'

    pid="$(cat "$pid_file")"
    kill "$pid"

    sleep 2
    rm -f -- "$pid_file"
  fi
fi

# Reuse a valid managed port-forward or create a new one.
if [[ -f "$pid_file" ]] &&
    is_gitlab_forward "$(cat "$pid_file")"; then

  echo "Existing kubectl port-forward: PID $(cat "$pid_file")"

else
  # Remove stale PID file.
  rm -f -- "$pid_file"

  # Do not silently reuse unknown listeners.
  if [[ -n "$(ss -H -ltn 'sport = :8081')" ]]; then

    echo 'ERROR: Port 8081 is already occupied.' >&2
    echo 'Inspect the existing listener with:' >&2
    echo "  sudo ss -ltnp 'sport = :8081'" >&2
    exit 1
  fi

  echo 'Starting GitLab port-forward.'

  nohup kubectl -n gitlab port-forward \
    --address 127.0.0.1 svc/gitlab 8081:8081 \
    > "$log_file" 2>&1 </dev/null &

  echo "$!" > "$pid_file"
fi

# Wait until GitLab becomes accessible.
ready=false

for ((n=1; n<=40; n++)); do

  if gitlab_reachable; then
    ready=true
    break
  fi

  sleep 3
done

if [[ "$ready" != true ]]; then
  echo "GitLab not responding. See $log_file" >&2
  exit 1
fi

echo "Local GitLab ready at $gitlab_url"

# Validate credentials against the GitLab database.
verify_root_password() {

  kubectl -n "$namespace" exec -i deployment/iot-gitlab -- \
    gitlab-rails runner '
      password = STDIN.read.chomp
      user = User.find_by!(username: "root")

      abort "Root account is not active." unless user.active?
      abort "Root account is locked." if user.access_locked?

      exit 42 unless user.valid_password?(password)

      puts "GitLab root password verified successfully."
    '
}

# Synchronize a verified password with local and Kubernetes storage.
sync_root_password() {
  local password="$1"
  local temp_file

  temp_file="$(mktemp "$state_dir/gitlab-password.XXXXXX")"

  if ! printf '%s' "$password" > "$temp_file" ||
     ! chmod 600 "$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi

  if ! kubectl -n "$namespace" create secret generic \
      iot-gitlab-bootstrap \
      --from-file="root-password=${temp_file}" \
      --dry-run=client -o yaml |
      kubectl apply -f -; then

    rm -f -- "$temp_file"
    return 1
  fi

  if ! mv -f -- "$temp_file" "$secret_file"; then
    rm -f -- "$temp_file"
    return 1
  fi

  chmod 600 "$secret_file"
}

# Explicitly change the GitLab administrator password.
change_root_password() {
  local new_password
  local confirm_password

  if [[ ! -t 0 ]]; then
    echo 'Password changes require an interactive terminal.' >&2
    return 1
  fi

  read -rsp 'Enter new GitLab root password: ' new_password
  echo

  read -rsp 'Confirm new GitLab root password: ' confirm_password
  echo

  if [[ "$new_password" != "$confirm_password" ]]; then
    echo 'ERROR: Passwords do not match.' >&2
    return 1
  fi

  if (( ${#new_password} < 12 )); then
    echo 'ERROR: Use at least 12 characters.' >&2
    return 1
  fi

  echo 'Changing GitLab administrator password.'

  if ! printf '%s' "$new_password" |
      kubectl -n "$namespace" exec -i deployment/iot-gitlab -- \
      gitlab-rails runner '
        password = STDIN.read
        user = User.find_by!(username: "root")

        user.password = password
        user.password_confirmation = password
        user.password_automatically_set = false
        user.save!

        abort "Password verification failed." unless
          user.reload.valid_password?(password)

        puts "GitLab root password changed successfully."
      '; then

    echo 'ERROR: Password change failed.' >&2
    return 1
  fi

  if ! sync_root_password "$new_password"; then
    echo 'ERROR: Password changed in GitLab,' >&2
    echo 'but credential synchronization failed.' >&2
    echo 'Rerun the access script to recover credentials.' >&2
    return 1
  fi

  unset new_password confirm_password

  echo 'GitLab password synchronized successfully.'
}

# Execute password change only when explicitly requested.
if [[ "$change_password" == true ]]; then

  change_root_password

else

  # Recover the local credential file if it is missing.
  if [[ ! -s "$secret_file" ]]; then

    echo 'Recovering GitLab bootstrap credentials.'

    kubectl -n "$namespace" get secret iot-gitlab-bootstrap \
      -o jsonpath='{.data.root-password}' |
      base64 --decode > "$secret_file"
  fi
fi

# Ensure that credentials are available.
if [[ ! -s "$secret_file" ]]; then
  echo 'ERROR: GitLab password file is empty.' >&2
  exit 1
fi

chmod 600 "$secret_file"

# Verify stored administrator credentials.
echo 'Verifying GitLab administrator credentials.'

if verify_root_password < "$secret_file"; then

  echo 'Stored credentials are valid.'

else
  result=$?

  if [[ "$result" -ne 42 ]]; then
    echo 'ERROR: Unable to verify GitLab credentials.' >&2
    exit 1
  fi

  echo 'The stored password no longer matches GitLab.'
  echo 'The administrator password may have been changed.'

  # Recover credentials without resetting the root account.
  if [[ ! -t 0 ]]; then
    echo 'Run this script interactively to update credentials.' >&2
    exit 1
  fi

  read -rsp 'Enter the current GitLab root password: ' current_password
  echo

  if ! printf '%s' "$current_password" | verify_root_password; then
    unset current_password
    echo 'ERROR: Credential verification failed.' >&2
    echo 'To set a new password, run:' >&2
    echo "  $0 --change-password" >&2
    exit 1
  fi

  if ! sync_root_password "$current_password"; then
    unset current_password
    echo 'ERROR: Credential synchronization failed.' >&2
    exit 1
  fi

  unset current_password

  echo 'GitLab credentials synchronized successfully.'
fi

# Display verified access information.
echo
echo '=========================================='
echo ' GitLab access configured successfully'
echo '=========================================='
echo "URL: $gitlab_url"
echo 'Username: root'
echo "Password: $(cat "$secret_file")"
echo '=========================================='
echo
echo 'To change the password:'
echo '  ./bonus/scripts/IoT-start-gitlab-access.sh --change-password'
echo
echo 'Next: ./bonus/scripts/IoT-bootstrap-local-repo.sh'
