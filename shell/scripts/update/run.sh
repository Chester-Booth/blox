#!/bin/bash
set -euo pipefail

if ! command -v arch-update >/dev/null; then
	echo "arch-update is required. Install it with: yay -S arch-update" >&2
	exit 127
fi

if ! command -v code >/dev/null; then
	echo "Visual Studio Code is required for pacnew diffs." >&2
	exit 127
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pacdiff_cache=""
previous_profile=""
profile_changed=0

restore_profile() {
	if ((profile_changed)) && ! asusctl profile set "$previous_profile"; then
		echo "Warning: failed to restore ASUS profile '$previous_profile'." >&2
	fi
}

cleanup() {
	restore_profile

	if [[ -n "$pacdiff_cache" ]]; then
		find "$pacdiff_cache" -mindepth 1 -maxdepth 1 -type l -delete
		rmdir -- "$pacdiff_cache"
	fi
}

trap cleanup EXIT

if command -v yay >/dev/null &&
	command -v asusctl >/dev/null &&
	[[ -n "$(yay -Qua 2>/dev/null)" ]]; then
	previous_profile=$(asusctl profile get | sed -n 's/^Active profile: //p')

	if [[ -n "$previous_profile" && "${previous_profile,,}" != "performance" ]]; then
		profile_changed=1
		asusctl profile set performance
	fi
fi

PATH="${script_dir}/skip-pacnew:${PATH}" arch-update

echo
echo "==> Processing pacnew files with Visual Studio Code..."
pacdiff_cache=$(mktemp -d --tmpdir blox-pacdiff-cache.XXXXXX)

while IFS= read -r -d '' package; do
	ln -s -- "$package" "$pacdiff_cache/"
done < <(
	find /var/cache/pacman/pkg -maxdepth 1 -type f \
		-name '*.pkg.tar*' ! -name '*.sig' -print0
)

DIFFPROG="code --wait --diff" /usr/bin/pacdiff -s --cachedir "$pacdiff_cache"
