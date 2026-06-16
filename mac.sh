# =============================================================================
# VARIABLES
# =============================================================================

# AWS
AWS_REGION="us-east-2"

# Redis
REDIS_PORT="6379"
REDIS_USER=""                  # TODO: fill in
REDIS_PASSWORD=""              # TODO: fill in
REDIS_HOST_STAGING="redis.redis.svc.cluster.local"
REDIS_HOST_QA="redis-headless.redis.svc.cluster.local"

# RabbitMQ
RABBITMQ_URL="http://rabbitmq.rabbitmq-system.svc.cluster.local:15672"
RABBITMQ_USER=""               # TODO: fill in
RABBITMQ_PASSWORD=""           # TODO: fill in

# Teleport — fill in after install
TELEPORT_PROXY="teleport.mymerchize.com:443"
TELEPORT_CLUSTER="teleport.mymerchize.com"
TELEPORT_USER=""               # TODO: fill in your Teleport email
TELEPORT_PASSWORD=""           # TODO: fill in your Teleport password
TELEPORT_TOTP_SECRET=""        # TODO: fill in your TOTP secret key


# =============================================================================
# LOGGING
# =============================================================================

_log()  { echo "[$(date '+%H:%M:%S')] $*"; }
_ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
_err()  { echo "[$(date '+%H:%M:%S')] ✗ $*" >&2; }
_warn() { echo "[$(date '+%H:%M:%S')] ! $*"; }


# =============================================================================
# SETUP
# =============================================================================

_brew_install() {
  local tool="$1" formula="${2:-$1}"
  if brew list "$formula" &>/dev/null; then
    _log "Upgrading $tool..."
    brew upgrade "$formula" 2>/dev/null && _ok "$tool upgraded" || _warn "$tool already at latest"
  else
    _log "Installing $tool..."
    brew install "$formula" && _ok "$tool installed" || { _err "Failed to install $tool"; return 1; }
  fi
}

# Installs or upgrades all tools required by functions in this file.
setup() {
  local errors=0

  # ── Homebrew ────────────────────────────────────────────────────────────────
  if ! command -v brew &>/dev/null; then
    _log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      && _ok "Homebrew installed" \
      || { _err "Failed to install Homebrew"; return 1; }
  else
    _log "Updating Homebrew..."
    brew update && _ok "Homebrew updated"
  fi

  # ── Tools ───────────────────────────────────────────────────────────────────
  _brew_install "kubectl"                                || (( errors++ ))
  _brew_install "awscli"                                 || (( errors++ ))
  _brew_install "kubevpn" "wencaiwulue/kubevpn/kubevpn" || (( errors++ ))
  _brew_install "teleport (tsh)" "teleport"              || (( errors++ ))
  _brew_install "expect"                                 || (( errors++ ))
  _brew_install "stern"                                  || (( errors++ ))

  # ── Summary ─────────────────────────────────────────────────────────────────
  echo
  if [[ $errors -eq 0 ]]; then
    _ok "Setup complete — all tools installed/upgraded"
    _warn "Restart your shell or run: source ~/.zshrc"
  else
    _err "Setup finished with $errors error(s) — check output above"
    return 1
  fi
}


# =============================================================================
# KUBECTL
# =============================================================================

# Routes kubectl through tsh when the active context is a Teleport cluster.
kubectl() {
  if [[ "$(command kubectl config current-context 2>/dev/null)" == *"teleport"* ]]; then
    tsh kubectl "$@"
  else
    command kubectl "$@"
  fi
}


# =============================================================================
# KUBERNETES HELPERS
# =============================================================================

# Switches the active kubectl context. Usage: switch-cluster [staging-nt|staging-nt-2|qa-nt|plf-staging-hetzner]
# plf-staging-hetzner uses TSH instead of AWS EKS.
switch-cluster() {
  local env="${1:-staging-nt}"
  local valid_envs=("staging-nt" "staging-nt-2" "qa-nt" "plf-staging-hetzner")

  if [[ ! " ${valid_envs[@]} " =~ " $env " ]]; then
    _err "Invalid env '$env'. Valid options: ${valid_envs[*]}"
    return 1
  fi

  if [[ "$env" == "plf-staging-hetzner" ]]; then
    _log "Connecting to $env via TSH..."
    if ! tsh-status &>/dev/null; then
      _warn "TSH session expired — logging in first"
      tsh login || { _err "TSH login failed"; return 1; }
    fi
    tsh kube login "$env" || { _err "Failed to switch context to $env"; return 1; }
    _ok "Switched to $env"
    return 0
  fi

  local current_ctx
  current_ctx=$(kubectl config current-context 2>/dev/null | sed 's|.*/cluster/||')

  if [[ "$current_ctx" == *"$env"* ]]; then
    _warn "Already using context for $env — skipping"
    return 0
  fi

  _log "Switching kubectl context to $env (region: $AWS_REGION)..."
  aws eks --region "$AWS_REGION" update-kubeconfig --name "$env" \
    || { _err "Failed to switch context to $env"; return 1; }
  _ok "Switched to $env"
}

# Switches the namespace in the current context. Usage: switch-namespace <namespace>
switch-namespace() {
  local ns="$1"

  if [[ -z "$ns" ]]; then
    _err "Usage: switch-namespace <namespace>"
    return 1
  fi

  _log "Checking namespace '$ns'..."
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    kubectl config set-context --current --namespace="$ns" >/dev/null
    _ok "Switched to namespace: $ns"
  else
    _err "Namespace '$ns' does not exist in the current context"
    return 1
  fi
}

# Prints the active kubectl context and namespace.
current-context() {
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null)

  if [[ -z "$ctx" ]]; then
    _err "No active kubectl context"
    return 1
  fi

  local ns
  ns=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)

  echo "Context  : ${ctx##*/}"
  echo "Namespace: ${ns:-default}"
}

# Port-forwards a deployment or service.
# Usage:
#   pf <resource>                  — auto-detect remote port, local = remote (auto-increment if busy)
#   pf <resource> <remote>         — use specified remote port, local = remote (auto-increment if busy)
#   pf <resource> <local>:<remote> — use both; error if local is busy or remote is wrong
pf() {
  local resource="$1"
  local port_arg="$2"

  if [[ -z "$resource" ]]; then
    _err "Usage: pf <deploy/name|svc/name> [local:]<remote>"
    return 1
  fi

  local kind name
  if [[ "$resource" == *"/"* ]]; then
    kind="${resource%%/*}"
    name="${resource##*/}"
  else
    kind="deploy"
    name="$resource"
  fi

  [[ "$kind" == "deployment" ]] && kind="deploy"
  [[ "$kind" == "service" ]]    && kind="svc"

  local arg_local="" arg_remote=""
  if [[ -n "$port_arg" ]]; then
    if [[ "$port_arg" == *":"* ]]; then
      arg_local="${port_arg%%:*}"
      arg_remote="${port_arg##*:}"
    else
      arg_remote="$port_arg"
    fi
    if ! [[ "$arg_remote" =~ ^[0-9]+$ ]]; then
      _err "Invalid remote port: '$arg_remote'"
      return 1
    fi
    if [[ -n "$arg_local" ]] && ! [[ "$arg_local" =~ ^[0-9]+$ ]]; then
      _err "Invalid local port: '$arg_local'"
      return 1
    fi
  fi

  local remote_port="$arg_remote"
  if [[ -z "$remote_port" ]]; then
    _log "Fetching ports for $kind/$name..."
    local ports_raw
    case "$kind" in
      deploy)
        ports_raw=$(kubectl get deploy "$name" \
          -o jsonpath='{range .spec.template.spec.containers[*]}{range .ports[*]}{.containerPort}{"\n"}{end}{end}' 2>/dev/null)
        ;;
      svc)
        ports_raw=$(kubectl get svc "$name" \
          -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}' 2>/dev/null)
        ;;
      *)
        _err "Unsupported resource type '$kind'. Use: deploy, svc"
        return 1
        ;;
    esac

    local ports=()
    while IFS= read -r p; do
      [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
    done <<< "$ports_raw"

    if [[ ${#ports[@]} -eq 0 && "$kind" == "deploy" ]]; then
      _warn "No containerPort in deploy spec — trying service '$name'..."
      local svc_raw
      svc_raw=$(kubectl get svc "$name" \
        -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}' 2>/dev/null)
      while IFS= read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] && ports+=("$p")
      done <<< "$svc_raw"
    fi

    if [[ ${#ports[@]} -eq 0 ]]; then
      _err "Could not detect any ports for $kind/$name"
      echo
      echo "  Available deployments in current namespace:"
      kubectl get deploy --no-headers 2>/dev/null | awk '{printf "    - %s\n", $1}' || echo "    (none)"
      echo "  Tip: specify port manually: pf $resource <remote-port>"
      echo
      return 1
    fi

    if [[ ${#ports[@]} -eq 1 ]]; then
      remote_port="${ports[1]}"
      _log "Detected port: $remote_port"
    else
      echo
      echo "  Multiple ports found for $kind/$name:"
      local idx=1
      for p in "${ports[@]}"; do
        echo "    [$idx] $p"
        (( idx++ ))
      done
      echo
      local choice
      read -rp "  Select port [1-${#ports[@]}]: " choice
      if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ports[@]} )); then
        _err "Invalid selection"
        return 1
      fi
      remote_port="${ports[$choice]}"
    fi
  fi

  local local_port="${arg_local:-$remote_port}"
  if [[ -n "$arg_local" ]]; then
    if lsof -iTCP:"$local_port" -sTCP:LISTEN &>/dev/null; then
      _err "Local port $local_port is already in use"
      _err "Specify a different local port: pf $resource $((local_port+1)):$remote_port"
      return 1
    fi
  else
    while lsof -iTCP:"$local_port" -sTCP:LISTEN &>/dev/null; do
      _warn "Local port $local_port is in use, trying $((local_port+1))..."
      (( local_port++ ))
    done
  fi

  _log "Starting port-forward: localhost:$local_port → $kind/$name:$remote_port"
  _log "Press Ctrl+C to stop"
  echo
  kubectl port-forward "$kind/$name" "$local_port:$remote_port"
  echo
  _ok "Port-forward stopped"
}


# =============================================================================
# SERVICE CONNECTIONS (via kubevpn)
# =============================================================================

# Connects to Redis via kubevpn and prints connection info. Usage: connect-redis [staging|qa]
connect-redis() {
  local env="${1:-staging}"

  if [[ "$env" != "staging" && "$env" != "qa" ]]; then
    _err "Invalid env '$env'. Use: staging | qa"
    return 1
  fi

  _log "Connecting to Redis ($env)..."

  _log "Requesting sudo access..."
  sudo -v || { _err "sudo authentication failed"; return 1; }

  _log "Disconnecting any existing kubevpn session..."
  sudo kubevpn disconnect --all >/dev/null 2>&1 || true

  _log "Switching kubectl context to ${env}-nt..."
  switch-cluster "${env}-nt" || { _err "Failed to switch cluster"; return 1; }

  _log "Starting kubevpn tunnel to namespace 'redis'..."
  sudo kubevpn connect -n redis || { _err "kubevpn connect failed"; return 1; }

  local host
  if [[ "$env" == "staging" ]]; then
    host="$REDIS_HOST_STAGING"
  else
    host="$REDIS_HOST_QA"
  fi

  _ok "Connected to Redis ($env)"
  echo
  echo "  Host    : $host"
  echo "  Port    : $REDIS_PORT"
  echo "  User    : $REDIS_USER"
  echo "  Password: $REDIS_PASSWORD"
  echo
  echo "  URI: redis://$REDIS_USER:$REDIS_PASSWORD@$host:$REDIS_PORT/2"
  echo
}

# Connects to RabbitMQ via kubevpn and prints connection info. Usage: connect-rabbitmq [staging|qa]
connect-rabbitmq() {
  local env="${1:-staging}"

  if [[ "$env" != "staging" && "$env" != "qa" ]]; then
    _err "Invalid env '$env'. Use: staging | qa"
    return 1
  fi

  _log "Connecting to RabbitMQ ($env)..."

  _log "Requesting sudo access..."
  sudo -v || { _err "sudo authentication failed"; return 1; }

  _log "Disconnecting any existing kubevpn session..."
  sudo kubevpn disconnect --all >/dev/null 2>&1 || true

  _log "Switching kubectl context to ${env}-nt..."
  switch-cluster "${env}-nt" || { _err "Failed to switch cluster"; return 1; }

  _log "Starting kubevpn tunnel to namespace 'rabbitmq-system'..."
  sudo kubevpn connect -n rabbitmq-system || { _err "kubevpn connect failed"; return 1; }

  _ok "Connected to RabbitMQ ($env)"
  echo
  echo "  URL     : $RABBITMQ_URL"
  echo "  User    : $RABBITMQ_USER"
  echo "  Password: $RABBITMQ_PASSWORD"
  echo
}


# =============================================================================
# TELEPORT (TSH)
# =============================================================================

# Generates a TOTP 6-digit code from TELEPORT_TOTP_SECRET using Python stdlib.
tsh-2fa() {
  if [[ -z "$TELEPORT_TOTP_SECRET" ]]; then
    _err "TELEPORT_TOTP_SECRET is not set — fill it in ~/.shell-kit/shell-kit.sh"
    return 1
  fi
  python3 - "$TELEPORT_TOTP_SECRET" <<'PYEOF'
import hmac, hashlib, struct, time, base64, sys
secret = sys.argv[1].upper().replace(' ', '')
key = base64.b32decode(secret + '=' * (-len(secret) % 8))
counter = struct.pack('>Q', int(time.time()) // 30)
mac = hmac.new(key, counter, hashlib.sha1).digest()
offset = mac[-1] & 0x0f
code = struct.unpack('>I', mac[offset:offset + 4])[0] & 0x7fffffff
print(f'{code % 1_000_000:06d}')
PYEOF
}

# Checks whether the current TSH session is still valid.
tsh-status() {
  if ! command -v tsh &>/dev/null; then
    _err "tsh not found in PATH"
    return 1
  fi

  local out
  out=$(tsh status 2>&1)

  if echo "$out" | grep -qi "not logged in\|no credentials"; then
    _warn "TSH: not logged in"
    return 1
  fi

  local expiry
  expiry=$(echo "$out" | grep -i "valid until\|expires" | head -1 | sed 's/.*: *//')
  if [[ -n "$expiry" ]]; then
    _ok "TSH: logged in — valid until $expiry"
  else
    _ok "TSH: logged in"
  fi
}

# tsh wrapper that auto-fills password and OTP for `tsh login`.
# All other subcommands are passed through to the real tsh binary.
tsh() {
  if [[ "$1" != "login" ]]; then
    command tsh "$@"
    return
  fi

  if [[ -z "$TELEPORT_PASSWORD" ]]; then
    _err "TELEPORT_PASSWORD is not set — fill it in ~/.shell-kit/shell-kit.sh"
    return 1
  fi

  local force=0
  [[ "$2" == "--force" ]] && force=1

  if [[ $force -eq 0 ]] && tsh-status &>/dev/null; then
    tsh-status
    _warn "Already logged in. Use 'tsh login --force' to re-authenticate."
    return 0
  fi

  local tsh_bin
  tsh_bin=$(command -v tsh) || { _err "tsh binary not found in PATH"; return 1; }

  _log "Generating 2FA code..."
  local code
  code=$(tsh-2fa) || { _err "Failed to generate 2FA code — check TELEPORT_TOTP_SECRET"; return 1; }
  _ok "2FA code generated: $code"

  if [[ $force -eq 1 ]]; then
    _log "Logging out existing session..."
    $tsh_bin logout &>/dev/null
  fi

  _log "Logging in to $TELEPORT_CLUSTER as $TELEPORT_USER..."
  expect -f - <<EXPECTEOF
log_user 0
set timeout 30
spawn $tsh_bin login --proxy=$TELEPORT_PROXY --auth=local --user=$TELEPORT_USER $TELEPORT_CLUSTER
expect {
  -re {(?i)password} {
    send "$TELEPORT_PASSWORD\r"
    expect -re {(?i)otp|one-time|authenticator|token}
    send "$code\r"
    exp_continue
  }
  -re {Logged in as:\s+(\S+)} {
    puts "\[OK\] TSH: logged in as \$expect_out(1,string)"
    exp_continue
  }
  -re {Valid until:\s+(.+)} {
    puts "\[OK\] TSH: session valid until \$expect_out(1,string)"
    exp_continue
  }
  -re {(?i)error|failed|invalid|incorrect} {
    puts "\[ERR\] TSH: login failed"
    exit 1
  }
  eof {}
}
EXPECTEOF
}
