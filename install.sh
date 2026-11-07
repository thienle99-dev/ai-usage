#!/bin/sh
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
    echo "AI Usage Monitor installer supports macOS only." >&2
    exit 1
fi

architecture=$(uname -m)
if [ "$architecture" != "arm64" ]; then
    echo "AI Usage Monitor installer currently supports Apple silicon Macs only." >&2
    exit 1
fi

macos_major=$(sw_vers -productVersion | awk -F. '{ print $1 }')
case "$macos_major" in
    ''|*[!0-9]*) echo "Could not determine the macOS version." >&2; exit 1 ;;
esac
if [ "$macos_major" -lt 14 ]; then
    echo "AI Usage Monitor requires macOS 14 or later." >&2
    exit 1
fi

for command_name in curl ditto; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command not found: $command_name" >&2
        exit 1
    fi
done

download_url="https://github.com/thienle99-dev/ai-usage/releases/latest/download/AI-Usage-Monitor-macos-arm64.zip"
install_directory=${AI_USAGE_INSTALL_DIR:-/Applications}
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/ai-usage-monitor.XXXXXX")
cleanup() {
    rm -rf "$work_directory"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

echo "Downloading the latest AI Usage Monitor release..."
if ! curl --fail --location --silent --show-error --retry 3 "$download_url" -o "$work_directory/app.zip"; then
    echo "Could not download the latest release. Check that a release has been published." >&2
    exit 1
fi

mkdir "$work_directory/extracted"
ditto -x -k "$work_directory/app.zip" "$work_directory/extracted"
app_source="$work_directory/extracted/AI Usage Monitor.app"
if [ ! -d "$app_source" ]; then
    echo "The release archive does not contain AI Usage Monitor.app." >&2
    exit 1
fi

if [ -d "$install_directory" ] && [ -w "$install_directory" ]; then
    ditto "$app_source" "$install_directory/AI Usage Monitor.app"
elif [ "$install_directory" = "/Applications" ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Writing to /Applications requires sudo. Set AI_USAGE_INSTALL_DIR to a writable folder to install without admin access." >&2
        exit 1
    fi

    echo "Administrator permission is required to install into /Applications."
    sudo -v
    sudo mkdir -p "$install_directory"
    sudo ditto "$app_source" "$install_directory/AI Usage Monitor.app"
else
    if ! mkdir -p "$install_directory"; then
        echo "Cannot create install directory: $install_directory" >&2
        exit 1
    fi
    if [ ! -w "$install_directory" ]; then
        echo "Cannot write to install directory: $install_directory" >&2
        echo "Choose a writable folder with AI_USAGE_INSTALL_DIR." >&2
        exit 1
    fi
    ditto "$app_source" "$install_directory/AI Usage Monitor.app"
fi
echo "Installed AI Usage Monitor to $install_directory/AI Usage Monitor.app"
