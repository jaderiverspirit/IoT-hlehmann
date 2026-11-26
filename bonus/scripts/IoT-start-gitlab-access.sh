#!/usr/bin/env bash
set -Eeuo pipefail
kubectl config current-context | grep -qx k3d-iot
kubectl -n gitlab get service gitlab >/dev/null

# Access the same GitLab URL from inside the Kubernetes cluster and the VM:
# inside: native Kubernetes DNS; outside: loopback + kubectl port-forward.
line='127.0.0.1 gitlab.gitlab.svc.cluster.local # IoT GitLab lab'
if ! grep -Fq "$line" /etc/hosts; then
  printf '%s\n' "$line" | sudo tee -a /etc/hosts >/dev/null
fi
state_dir="${HOME}/.config/iot"
mkdir -p "$state_dir"
chmod 700 "$state_dir"
pid_file="$state_dir/gitlab-portforward.pid"
# Validate that the saved PID belongs to our GitLab port-forward.
is_gitlab_forward() {
  local pid="${1:-}"
  local cmd

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  cmd="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1

  [[ "$cmd" == 'kubectl -n gitlab port-forward --address 127.0.0.1 svc/gitlab 8081:8081' ]]
}

# Recover an unresponsive managed port-forward.
if [[ -f "$pid_file" ]] && is_gitlab_forward "$(cat "$pid_file")"; then
  if ! curl --noproxy '*' --silent --fail \
      --connect-timeout 3 --max-time 5 \
      'http://gitlab.gitlab.svc.cluster.local:8081/users/sign_in' \
      >/dev/null; then

    # Do not restart forwarding if GitLab itself is unavailable.
    if ! kubectl -n gitlab rollout status deployment/iot-gitlab \
        --timeout=15s >/dev/null; then
      echo 'ERROR: GitLab deployment is not ready.' >&2
      exit 1
    fi

    pid="$(cat "$pid_file")"
    if is_gitlab_forward "$pid"; then
      echo 'Restarting unresponsive managed GitLab port-forward.'
      kill "$pid"
      sleep 2
      rm -f -- "$pid_file"
    fi
  fi
fi

if [[ -f "$pid_file" ]] && is_gitlab_forward "$(cat "$pid_file")"; then
  echo "Existing kubectl port-forward: PID $(cat "$pid_file")"
elif curl --noproxy '*' --silent --fail \
    --connect-timeout 3 --max-time 5 \
    'http://gitlab.gitlab.svc.cluster.local:8081/users/sign_in' \
    >/dev/null; then
  echo 'GitLab is already accessible through an existing connection.'
  echo 'Reusing connection without starting another port-forward.'
else
  # Do not start another listener if port 8081 is occupied.
  if [[ -n "$(ss -H -ltn 'sport = :8081')" ]]; then
    echo 'ERROR: Port 8081 is occupied, but GitLab is unreachable.' >&2
    echo 'Inspect the listener with:' >&2
    echo "  sudo ss -ltnp 'sport = :8081'" >&2
    echo 'Resolve the port conflict and rerun this script.' >&2
    exit 1
  fi

  nohup kubectl -n gitlab port-forward --address 127.0.0.1 \
	svc/gitlab 8081:8081 > "$state_dir/gitlab-portforward.log" 2>&1 </dev/null &
  echo "$!" > "$pid_file"
fi
for n in $(seq 1 40); do
  if curl --noproxy '*' --silent --fail --max-time 5 \
	'http://gitlab.gitlab.svc.cluster.local:8081/users/sign_in' >/dev/null; then
	echo 'Local GitLab ready at http://gitlab.gitlab.svc.cluster.local:8081'
	echo 'GitLab username: root'
	echo "Initial password: $(cat "$state_dir/gitlab-root-password")"
	exit 0
  fi
  sleep 3
done
echo 'GitLab not responding. See ~/.config/iot/gitlab-portforward.log' >&2
exit 1
