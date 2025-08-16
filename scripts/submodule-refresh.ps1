git submodule deinit -f --all
git submodule sync --recursive
git submodule update --init --recursive --progress
git submodule update --remote --recursive --progress
