#!/bin/bash
# Double-click in Finder to install or update Flickwise (runs install.sh).
cd "$(dirname "$0")"
bash ./install.sh
echo
read -r -p "Press Enter to close this window… " _
