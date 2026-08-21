#!/bin/bash

if pgrep -x nm-applet >/dev/null; then
	notify-send -u low -e "Network Manager Applet Off" "applet has been turned off"
	pkill nm-applet
else
	nm-applet --indicator &
	notify-send -u low -e "Network Manager Applet On" "applet has been turned on"
fi
