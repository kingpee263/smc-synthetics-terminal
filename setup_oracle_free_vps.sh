#!/bin/bash
# ==============================================================================
# SMC Auto-Desk: 24/7 Oracle Cloud Free Tier Setup & Headless Runner
# Runs Deriv MT5 & Weltrade MT5 inside free Ubuntu 22.04 LTS via Wine & Xvfb
# ==============================================================================

echo "===================================================================="
echo "  SMC AUTO-DESK: ORACLE CLOUD FREE TIER 24/7 INSTALLER & RUNNER    "
echo "===================================================================="

# Update and install Wine, Xvfb (Virtual Display), and PowerShell
sudo dpkg --add-architecture i386
sudo apt update -y
sudo apt install -y wine wine32 wine64 xvfb x11vnc wget curl git

# Install PowerShell Core for Linux
sudo apt install -y wget apt-transport-https software-properties-common
source /etc/os-release
wget -q https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo apt update -y
sudo apt install -y powershell

# Set up virtual display for headless MT5
export DISPLAY=:99
Xvfb :99 -screen 0 1024x768x16 &

echo "[INFO] Headless virtual display active on DISPLAY=:99"

# Clone/pull latest SMC Auto-Desk repository
if [ ! -d "$HOME/smc-synthetics-terminal" ]; then
    git clone https://github.com/kingpee263/smc-synthetics-terminal.git "$HOME/smc-synthetics-terminal"
else
    cd "$HOME/smc-synthetics-terminal" && git pull origin main
fi

cd "$HOME/smc-synthetics-terminal"

# Launch 24/7 background server via pwsh
nohup pwsh -NoProfile -File server.ps1 > server.log 2>&1 &
echo "[SUCCESS] 24/7 SMC Server running in background on port 8095!"
echo "[INFO] Logs available at $HOME/smc-synthetics-terminal/server.log"
