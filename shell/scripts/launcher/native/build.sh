#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
	echo "usage: $0 OUTPUT_DIR" >&2
	exit 2
fi

output_dir="$1"
mkdir -p "$output_dir"
rustc --edition=2021 -O dmenu_server.rs -o "$output_dir/dmenu-server-rust"
g++ -std=c++20 -O2 -Wall -Wextra -Werror dmenu_server.cpp -o "$output_dir/dmenu-server-cpp"
strip --strip-unneeded "$output_dir/dmenu-server-rust" "$output_dir/dmenu-server-cpp"
