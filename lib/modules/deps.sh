# shellcheck shell=bash
# shellcheck disable=SC2034  # PROBE/NOTE/global dipakai lintas file
# modul: deps — alat dasar yang harus ada sebelum apa pun.

m_deps_probe() {
  local b miss=()
  for b in curl tar sha256sum gzip unzip awk sed; do
    have "$b" || miss+=("$b")
  done
  if [ "${#miss[@]}" -eq 0 ]; then
    PROBE=OK; NOTE="curl tar sha256sum gzip unzip awk sed"
  else
    PROBE=MISS; NOTE="kurang: ${miss[*]}"
  fi
}
