# requirements: ssh-to-age nixos-anywhere

HECTIC_NAMESPACE="deploy"

# ssh proxydoe 'cat /etc/os-release 2>/dev/null || echo "no /etc/os-release"' | grep '^NAME=NixOS$'
# NAME=NixOS

# ssh that not saves the host in ~/.ssh/know_hosts
puressh() {
  local known_hosts="${HECTIC_DEPLOY_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
  local identity_file="${HECTIC_DEPLOY_IDENTITY_FILE:-$HOME/.ssh/id_ed25519}"
  local ssh_config="${HECTIC_DEPLOY_SSH_CONFIG:-}"
  if [ -n "$ssh_config" ]; then
    set -- -F "$ssh_config" "$@"
  fi
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$known_hosts" -o IdentitiesOnly=yes \
    -i "$identity_file" "$@"
}

# echo <gens_list> | find_older_gen(gen) 
find_older_gen() {
  local gen="${1:?}"
  grep -oP '(?<=system-)\d+(?=-link)' \
    | sort -n \
    | awk -v n="$gen" '$1 < n {older=$1} END{if(older) print older}'
}

saved_args="$*"

# parse command and independent params
while [ $# -gt 0 ]; do
  case $1 in
    push)
      if [ ${founded_command+x} ]; then
        # shellcheck disable=SC2016
        log error "ambiguous subcommand \`$1\` and \`$founded_command\`"
        exit 2
      fi

      push_deploy=1
      founded_command="$1"
      shift
      ;;
    rollback)
      if [ ${founded_command+x} ]; then
        # shellcheck disable=SC2016
        log error "ambiguous subcommand \`$1\` and \`$founded_command\`"
        exit 2
      fi

      rollback_deploy=1
      founded_command="$1"
      shift
      ;;
    history)
      if [ ${founded_command+x} ]; then
        # shellcheck disable=SC2016
        log error "ambiguous subcommand \`$1\` and \`$founded_command\`"
        exit 2
      fi

      server_history=1
      founded_command="$1"
      shift
      ;;
    --target-host)
      target_host=$2
      shift 2
      ;;
    -y|--yes)
      assume_yes=1
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      shift
      ;;
  esac
done

# shellcheck disable=SC2086
set -- $saved_args

# parse sub params
while [ $# -gt 0 ]; do
  case $1 in
    --init)
      if [ ${push_deploy+x} ]; then
        server_init=1
      else
        log warn "illegal $1"
      fi 
      shift
      ;;
    --to)
      if [ ${rollback_deploy+x} ]; then
        rollback_to="$2"
      else
        log warn "illegal $1"
      fi
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      shift
      ;;
  esac
done

# NOTE(yukkop): 
# after "end of arguments" (--)
# need to parse nix argument `--target-host`
# without lost of $@, that can be ruined by `shift`
saved_nix_args="$*"

while [ $# -gt 0 ]; do
  case $1 in
    --target-host)
      if [ "${target_host+x}" ] && [ "$target_host" != "$2" ]; then
        log error "you specified 2 ambiguous target hosts \`$target_host\` and \`$2\`"
        exit 2
      fi

      target_host="$2"
      break
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# NOTE: restore original args
# shellcheck disable=SC2086
set -- $saved_nix_args

if ! [ ${target_host+x} ]; then
  log error "$(printf '%s' '--target-host') not set, but required"
  exit 3
fi

if puressh "$target_host" 'cat /etc/os-release 2>/dev/null || echo "no /etc/os-release"' \
  | grep -q '^NAME=NixOS$'
then
  is_target_host_nixos=1
else
  is_target_host_nixos=0
fi

#??
#ssh "$target_host" 'grep -q "^NAME=NixOS$" /etc/os-release 2>/dev/null'
#is_target_host_nixos=$?

if [ "${rollback_deploy+x}" ]; then
  if ! [ "${rollback_to+x}" ]; then
    current_gen=$(puressh "$target_host" readlink /nix/var/nix/profiles/system \
      | sed -n 's/^system-\([0-9]\+\)-link$/\1/p')

    rollback_to=$(puressh "$target_host" ls /nix/var/nix/profiles | find_older_gen "$current_gen")

    if [ -z "$rollback_to" ]; then
      # shellcheck disable=SC2016
      log error "no profile version older than the current \`$current_gen\` exists"
      exit
    fi

  else
    if ! puressh "$target_host" ls /nix/var/nix/profiles \
      | grep -oP '(?<=system-)'"$rollback_to"'(?=-link)' > /dev/null
    then
      # shellcheck disable=SC2016
      log error 'no profile version \`$rollback_to\` exists'
      exit
    fi
  fi

  puressh "$target_host" <<EOF
    sudo nix profile rollback --profile /nix/var/nix/profiles/system --to '$rollback_to'
    sleep 1
    sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
EOF
fi

if [ "${server_history+x}" ]; then
  puressh "$target_host" nix profile history --profile /nix/var/nix/profiles/system
  exit 0
fi

if [ "${push_deploy+x}" ]; then
  if [ "${server_init+x}" ]; then
    if [ "$is_target_host_nixos" -eq 1 ]; then
      log warn 'target host already is nixos, are you really want to reinstall nixos?'
      if [ "${assume_yes+x}" ]; then
        log info 'assuming yes (-y/--yes), proceeding with reinstall'
      else
        printf 'This may delete all data [y/N]\n'
        read -r CONTINUE
        if [ "$CONTINUE" != "y" ]; then
          exit 0
        fi
      fi
    fi
  
    # shellcheck disable=SC2068
    nixos-anywhere -- $@ # --flake .#x86_64-linux --target-host proxydoe

    log info "waiting for $target_host to become reachable via ssh..."
    while ! puressh "$target_host" true 2>/dev/null; do
       sleep 5
    done
    
    server_public_age_key=$(puressh "$target_host" cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age)

  
    # shellcheck disable=SC2016
    log info "server's public age key is \`$server_public_age_key\` use it in sops file and run regular deploys"
  else
    if [ "$is_target_host_nixos" -ne 1 ]; then
      log error 'remote system not nixos'
      exit 1
    fi
  
    # shellcheck disable=SC2068
    nixos-rebuild switch $@ # --flake .#x86_64-linux --target-host proxydoe
  fi
fi
