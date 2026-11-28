#!/bin/sh
set -eu

token_file="${HOME}/.config/iot/gitlab-bootstrap-token"
gitlab_host="gitlab.gitlab.svc.cluster.local:8081"
prompt="${1:-}"

# Never provide credentials to an unexpected destination.
case "$prompt" in
  *"http://${gitlab_host}'"*|\
  *"http://root@${gitlab_host}'"*|\
  *"http://${gitlab_host}/"*|\
  *"http://root@${gitlab_host}/"*)
    ;;
  *)
    echo 'ERROR: Unexpected Git authentication destination.' >&2
    exit 1
    ;;
esac

case "$prompt" in
  *sername*)
    printf 'root\n'
    ;;

  *assword*)
    if [ ! -r "$token_file" ] || [ ! -s "$token_file" ]; then
      echo 'ERROR: GitLab bootstrap token missing or unreadable.' >&2
      echo 'Run IoT-bootstrap-local-repo.sh first.' >&2
      exit 1
    fi

    printf '%s\n' "$(cat "$token_file")"
    ;;

  *)
    echo 'ERROR: Unsupported Git authentication prompt.' >&2
    exit 1
    ;;
esac
