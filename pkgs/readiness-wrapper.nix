# Kubernetes control-plane binaries have no sd_notify support
# (kubernetes/kubernetes#8311), so real systemd readiness ordering needs a
# wrapper: exec the component in the background, poll its health endpoint,
# then signal READY=1. Units using this must set Type=notify and
# NotifyAccess=all (the notifier is not the main PID).
{
  lib,
  writeShellApplication,
  curl,
  systemd,
}:
writeShellApplication {
  name = "kubenyx-ready-wrap";
  runtimeInputs = [
    curl
    systemd
  ];
  text = ''
    url=""
    curl_opts=(--silent --fail --max-time 2)
    while [ $# -gt 0 ]; do
      case "$1" in
        --url) url="$2"; shift 2 ;;
        --cacert) curl_opts+=(--cacert "$2"); shift 2 ;;
        --cert) curl_opts+=(--cert "$2"); shift 2 ;;
        --key) curl_opts+=(--key "$2"); shift 2 ;;
        --insecure) curl_opts+=(--insecure); shift ;;
        --) shift; break ;;
        *) echo "kubenyx-ready-wrap: unknown option $1" >&2; exit 2 ;;
      esac
    done
    if [ -z "$url" ] || [ $# -eq 0 ]; then
      echo "usage: kubenyx-ready-wrap --url URL [tls opts] -- cmd args..." >&2
      exit 2
    fi

    "$@" &
    child=$!
    trap 'kill -TERM "$child" 2>/dev/null || true' TERM INT

    while ! curl "''${curl_opts[@]}" --output /dev/null "$url"; do
      if ! kill -0 "$child" 2>/dev/null; then
        wait "$child"
        exit $?
      fi
      sleep 0.2
    done
    systemd-notify --ready || true
    wait "$child"
  '';
}
