#!/usr/bin/env bash
# User-local Cisco Packet Tracer installer for Debian packages containing an AppImage.
set -Eeuo pipefail

APP_NAME='Cisco Packet Tracer'
DOWNLOAD_DIR="${HOME}/Downloads"
APP_DIR="${HOME}/.local/opt/packettracer"
BIN_DIR="${HOME}/.local/bin"
COMMAND_PATH="${BIN_DIR}/packettracer"
DESKTOP_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
DESKTOP_PATH="${DESKTOP_DIR}/packettracer.desktop"
DOWNLOAD_URL='https://www.netacad.com/resources/lab-downloads'

info()  { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Usage: packettracer.sh [install|update|uninstall|status] [path/to/CiscoPacketTracer*.deb]

  install     Install or replace Packet Tracer (default)
  update      Replace an existing installation with a supplied .deb
  uninstall   Remove the user-local installation and launcher
  status      Report the current installation status

Without a package argument, install/update search ~/Downloads for a single
CiscoPacketTracer*.deb file. No sudo is required.
HELP
}

missing_package() {
    cat >&2 <<EOF_HELP
[ERROR] Cisco Packet Tracer .deb package not found.

To download it:
  1. Open Cisco Networking Academy: ${DOWNLOAD_URL}
  2. Sign in with your Cisco Networking Academy account (or create one).
  3. In the Resource Hub, find Cisco Packet Tracer downloads.
  4. Choose the Ubuntu/Linux 64-bit .deb installer.
  5. Save the .deb file to ${DOWNLOAD_DIR}
  6. Run this script again:
       ./packettracer.sh install

If you saved the package elsewhere, specify its full path:
  ./packettracer.sh install /path/to/CiscoPacketTracer_version_Ubuntu_64bit.deb

Download only from Cisco's official website.
EOF_HELP
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

check_dependencies() {
    local cmd
    for cmd in ar tar mktemp find grep chmod mkdir mv rm ln basename readlink rmdir; do
        require_cmd "$cmd"
    done
}

resolve_package() {
    local -a matches=()
    if (($#)); then
        DEB_FILE="$1"
        if [[ ! -f "$DEB_FILE" ]]; then
            warn "Package not found at specified path: $DEB_FILE"
            missing_package
        fi
        [[ -r "$DEB_FILE" ]] || error "Package is not readable: $DEB_FILE"
        return
    fi
    shopt -s nullglob
    matches=("${DOWNLOAD_DIR}"/CiscoPacketTracer*.deb "${DOWNLOAD_DIR}"/Packet_Tracer*.deb)
    shopt -u nullglob
    ((${#matches[@]})) || missing_package
    if ((${#matches[@]} > 1)); then
        printf '[ERROR] Multiple Packet Tracer packages found:\n' >&2
        printf '  %s\n' "${matches[@]}" >&2
        error 'Pass one exact .deb path: ./packettracer.sh install /path/to/file.deb'
    fi
    DEB_FILE="${matches[0]}"
}

installed() {
    [[ -d "$APP_DIR" && -f "$APP_DIR/AppRun" ]]
}

status() {
    if installed; then
        info "$APP_NAME is installed for this user."
        printf 'Application: %s\n' "$APP_DIR"
        [[ ! -f "$APP_DIR/.source-package" ]] || {
            printf 'Source package: '; cat "$APP_DIR/.source-package"
        }
        if [[ -L "$COMMAND_PATH" && "$(readlink "$COMMAND_PATH")" == "$APP_DIR/AppRun" ]]; then
            printf 'Command: %s\n' "$COMMAND_PATH"
        else
            warn 'Command shortcut is missing or points elsewhere.'
        fi
        [[ ! -f "$DESKTOP_PATH" ]] || printf 'Desktop launcher: %s\n' "$DESKTOP_PATH"
    else
        info "$APP_NAME is not installed at $APP_DIR"
    fi
}

uninstall() {
    if [[ -L "$COMMAND_PATH" && "$(readlink "$COMMAND_PATH")" == "$APP_DIR/AppRun" ]]; then
        rm -- "$COMMAND_PATH"
    fi
    if [[ -f "$DESKTOP_PATH" ]] && grep -q '^X-PacketTracer-UserInstaller=true$' "$DESKTOP_PATH"; then
        rm -- "$DESKTOP_PATH"
    fi
    if [[ -L "$APP_DIR" ]]; then
        error "Refusing to remove symbolic-link installation directory: $APP_DIR"
    fi
    if [[ -d "$APP_DIR" ]]; then
        rm -rf -- "$APP_DIR"
        info 'Packet Tracer application files removed.'
    else
        info 'No user-local Packet Tracer installation was found.'
    fi
    info 'Personal preferences and saved projects were left untouched.'
}

# A failed install restores the previous application, symlink and desktop file.
WORK_DIR=''
NEW_DIR=''
OLD_DIR=''
BACKUP_LINK=''
BACKUP_DESKTOP=''
SUCCESS=false
APP_SWAPPED=false
LINK_TOUCHED=false
DESKTOP_TOUCHED=false

cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$SUCCESS" != true ]]; then
        if [[ "$DESKTOP_TOUCHED" == true ]]; then
            rm -f -- "$DESKTOP_PATH"
            if [[ -n "$BACKUP_DESKTOP" && -f "$BACKUP_DESKTOP" ]]; then
                mv -- "$BACKUP_DESKTOP" "$DESKTOP_PATH"
            fi
        fi
        if [[ "$LINK_TOUCHED" == true ]]; then
            rm -f -- "$COMMAND_PATH"
            if [[ -n "$BACKUP_LINK" && ( -e "$BACKUP_LINK" || -L "$BACKUP_LINK" ) ]]; then
                mv -- "$BACKUP_LINK" "$COMMAND_PATH"
            fi
        fi
        if [[ "$APP_SWAPPED" == true ]]; then
            rm -rf -- "$APP_DIR"
            if [[ -n "$OLD_DIR" && -d "$OLD_DIR" ]]; then
                mv -- "$OLD_DIR" "$APP_DIR"
            fi
        fi
    fi
    [[ -z "$NEW_DIR" || ! -d "$NEW_DIR" ]] || rm -rf -- "$NEW_DIR"
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
    return "$result"
}

choose_icon() {
    local path
    ICON_PATH='applications-education'
    while IFS= read -r path; do
        case "${path,,}" in
            *packet*tracer*.png|*packet*tracer*.svg|*/pt.png|*/pt.svg)
                ICON_PATH="$path"
                return
                ;;
        esac
    done < <(find "$NEW_DIR" -type f \( -iname '*.png' -o -iname '*.svg' \) -print)
}

install_package() {
    local action="$1" source_member appimage_rel appimage data_archive entry
    shift

    if [[ "$action" == update ]] && ! installed; then
        error 'Packet Tracer is not installed. Run: ./packettracer.sh install'
    fi
    check_dependencies
    resolve_package "$@"
    info "Using package: $DEB_FILE"

    [[ ! -L "$APP_DIR" ]] || error "Refusing to replace symlink: $APP_DIR"
    if [[ -e "$COMMAND_PATH" || -L "$COMMAND_PATH" ]]; then
        [[ -L "$COMMAND_PATH" && "$(readlink "$COMMAND_PATH")" == "$APP_DIR/AppRun" ]] ||
            error "Unmanaged command already exists: $COMMAND_PATH"
    fi
    if [[ -e "$DESKTOP_PATH" ]]; then
        grep -q '^X-PacketTracer-UserInstaller=true$' "$DESKTOP_PATH" ||
            error "Unmanaged desktop entry already exists: $DESKTOP_PATH"
    fi

    WORK_DIR="$(mktemp -d)"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    data_archive=''
    while IFS= read -r entry; do
        case "$entry" in
            data.tar|data.tar.gz|data.tar.xz|data.tar.zst|data.tar.bz2)
                data_archive="$entry"; break ;;
        esac
    done < <(ar t "$DEB_FILE")
    [[ -n "$data_archive" ]] || error 'No supported data.tar archive found in .deb'

    ar p "$DEB_FILE" "$data_archive" > "$WORK_DIR/$data_archive"
    appimage_rel=''
    while IFS= read -r entry; do
        case "$entry" in
            *.AppImage) appimage_rel="$entry"; break ;;
        esac
    done < <(tar -tf "$WORK_DIR/$data_archive")
    [[ -n "$appimage_rel" ]] || error 'This .deb has no embedded AppImage; its format may be unsupported.'
    # Only extract a non-traversing relative file path.
    source_member="${appimage_rel#./}"
    case "/$source_member/" in
        *'/../'*|*'/./'*|*'//'*) error 'Unsafe AppImage archive path detected.' ;;
    esac
    [[ "$source_member" != /* && "$source_member" != '..' ]] || error 'Unsafe AppImage archive path.'

    info 'Extracting embedded AppImage...'
    tar -xf "$WORK_DIR/$data_archive" -C "$WORK_DIR" -- "$appimage_rel"
    appimage="$WORK_DIR/$source_member"
    [[ -f "$appimage" && ! -L "$appimage" ]] || error 'Embedded AppImage is missing or not a regular file.'
    chmod u+x "$appimage"
    (
        cd "$WORK_DIR"
        "$appimage" --appimage-extract >/dev/null
    ) || error 'AppImage extraction failed. Check compatibility and dependencies.'
    [[ -f "$WORK_DIR/squashfs-root/AppRun" ]] || error 'AppRun missing from extracted AppImage.'

    # Stage the new application alongside the target to ensure same-filesystem renames.
    mkdir -p "$(dirname "$APP_DIR")" "$BIN_DIR" "$DESKTOP_DIR"
    NEW_DIR="$(mktemp -d "$(dirname "$APP_DIR")/.packettracer-new.XXXXXXXX")"
    mv -- "$WORK_DIR/squashfs-root" "$NEW_DIR/app"
    # Move staged folder's contents as a single directory after removing empty wrapper.
    mv -- "$NEW_DIR/app" "$NEW_DIR/contents"
    printf '%s\n' "$(basename "$DEB_FILE")" > "$NEW_DIR/contents/.source-package"
    chmod u+x "$NEW_DIR/contents/AppRun"
    mv -- "$NEW_DIR/contents" "$NEW_DIR/app"

    # Desktop icon paths need to point to the final installation, not the staging area.
    choose_icon
    if [[ "$ICON_PATH" == "$NEW_DIR/"* ]]; then
        ICON_PATH="$APP_DIR/${ICON_PATH#"$NEW_DIR/app/"}"
    fi
    cat > "$WORK_DIR/packettracer.desktop" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=Cisco Packet Tracer
Comment=Network simulation and learning
Exec=${COMMAND_PATH}
TryExec=${COMMAND_PATH}
Icon=${ICON_PATH}
Terminal=false
Categories=Education;Network;
StartupNotify=true
X-PacketTracer-UserInstaller=true
EOF_DESKTOP

    if [[ -d "$APP_DIR" ]]; then
        OLD_DIR="$(mktemp -d "$(dirname "$APP_DIR")/.packettracer-old.XXXXXXXX")"
        rmdir "$OLD_DIR"
        mv -- "$APP_DIR" "$OLD_DIR"
    fi
    APP_SWAPPED=true
    mv -- "$NEW_DIR/app" "$APP_DIR"

    if [[ -L "$COMMAND_PATH" ]]; then
        BACKUP_LINK="$WORK_DIR/old-command"
        mv -- "$COMMAND_PATH" "$BACKUP_LINK"
    fi
    LINK_TOUCHED=true
    ln -s -- "$APP_DIR/AppRun" "$COMMAND_PATH"

    if [[ -f "$DESKTOP_PATH" ]]; then
        BACKUP_DESKTOP="$WORK_DIR/old-desktop"
        mv -- "$DESKTOP_PATH" "$BACKUP_DESKTOP"
    fi
    DESKTOP_TOUCHED=true
    mv -- "$WORK_DIR/packettracer.desktop" "$DESKTOP_PATH"

    SUCCESS=true
    [[ -z "$OLD_DIR" ]] || rm -rf -- "$OLD_DIR"
    info 'Cisco Packet Tracer installed successfully (no sudo).'
    printf 'Launch: %s\n' "$COMMAND_PATH"
    if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
        printf 'Or simply: packettracer\n'
    else
        printf 'Add ~/.local/bin to PATH to use: packettracer\n'
        printf 'For Bash: echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc\n'
    fi
    info 'The application should also appear in your desktop launcher.'
}

main() {
    local action="${1:-install}"
    case "$action" in
        -h|--help|help) usage ;;
        install|update)
            (($# == 0)) || shift
            (($# <= 1)) || error 'Specify at most one .deb file.'
            install_package "$action" "$@"
            ;;
        uninstall) (($# == 1)) || error 'uninstall takes no package argument'; uninstall ;;
        status) (($# == 1)) || error 'status takes no package argument'; status ;;
        *) error "Unknown command: $action (see --help)" ;;
    esac
}
main "$@"
