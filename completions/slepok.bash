# shellcheck shell=bash
# Автодополнение для slepok: команды, параметры и имена снимков.

_slepok() {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD - 1]}"
  local commands="backup list prune diff history restore check help"
  local -a config=()
  local i word command=""

  for (( i = 1; i < COMP_CWORD; i++ )); do
    word="${COMP_WORDS[i]}"
    case "$word" in
      -c | --config) config=(-c "${COMP_WORDS[i + 1]}"); i=$((i + 1)) ;;
      -*) ;;
      *) if [[ -z "$command" ]]; then command="$word"; fi ;;
    esac
  done

  if [[ "$prev" == -c || "$prev" == --config ]]; then
    mapfile -t COMPREPLY < <(compgen -f -- "$cur")
    return
  fi
  if [[ "$cur" == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "-c --config -n --dry-run -q --quiet -h --help -V --version --no-prune --names" -- "$cur")
    return
  fi

  case "$command" in
    "")
      mapfile -t COMPREPLY < <(compgen -W "$commands" -- "$cur")
      ;;
    diff | restore)
      local snaps
      snaps="$(slepok "${config[@]}" list --names 2> /dev/null)"
      mapfile -t COMPREPLY < <(compgen -W "latest previous $snaps" -- "$cur")
      if [[ "$command" == restore && ${#COMPREPLY[@]} -eq 0 ]]; then
        mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      fi
      ;;
    history)
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      ;;
  esac
}

complete -F _slepok slepok
