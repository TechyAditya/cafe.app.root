git submodule deinit -f --all
git submodule sync --recursive
git submodule update --init --recursive --progress
git submodule foreach --recursive '
  b=$(git config -f "$toplevel/.gitmodules" submodule.$name.branch)
  : "${b:=main}"                                     # fallback if not set
  git fetch origin
  git switch -C "$b" --track "origin/$b" 2>/dev/null \
    || git switch "$b"                              \
    || echo "[$name] no branch $b"
'
