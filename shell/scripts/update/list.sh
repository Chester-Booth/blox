#!/bin/bash

echo "Fetching updates list..."

# get official repo updates
repo_updates=$(checkupdates 2>/dev/null | wc -l)

# get AUR updates
aur_updates=$(yay -Qua 2>/dev/null | wc -l)

{
	echo "=== Official Repositories ==="
	echo "$repo_updates updates available"
	checkupdates
	echo ""
	echo "=== AUR ==="
	echo "$aur_updates updates available"
	yay -Qua
} | less -SR
