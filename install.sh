#!/bin/bash
# Build Sotto from source and install it.
#
#   curl -fsSL https://raw.githubusercontent.com/AndreiStolojan/Sotto/main/install.sh | bash
#   ./install.sh [--beta] [--uninstall] [--help]
#
# The script clones (or updates) the source into ~/Library/Caches/Sotto, builds it in Release with
# scripts/build.sh, quits the running copy, installs to /Applications (or ~/Applications) and launches it.
set -euo pipefail

repo_url="${SOTTO_REPO:-https://github.com/AndreiStolojan/Sotto.git}"
cache_root="$HOME/Library/Caches/Sotto"
cache_marker=.sotto-installer
# Set in main and used by the install functions and the exit trap.
app_name="" bundle_id="" dest="" stage="" backup=""
min_macos=15
min_xcode=26

usage() {
    cat <<'EOF'
Usage: install.sh [--beta] [--uninstall] [--help]

Builds Sotto from source and installs it.

  (no flags)    Build the stable channel (main branch) and install Sotto.app.
  --beta        Build the beta branch as "Sotto Beta.app", a separate app with
                its own settings and data. It can run next to the stable app.
  --uninstall   Quit and remove the installed app (add --beta for the beta app).
                Your settings, history and models stay; the script prints where.
  --help        Show this help.

Environment:
  SOTTO_REPO               Git URL or local path to build from (default: GitHub).
  SOTTO_INSTALL_DIR        Install into this folder instead of /Applications.
  SOTTO_NO_LAUNCH=1        Install without launching the app.
  SOTTO_CODESIGN_IDENTITY  Sign with this certificate so macOS keeps permissions
                           across updates (see the README).
EOF
}

step() { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

check_system() {
    [[ "$(uname -s)" == Darwin ]] || fail "Sotto is a macOS app. Run this on a Mac."

    local version major
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    (( major >= min_macos )) || fail "Sotto needs macOS $min_macos or newer. This Mac runs $version."

    case "$(uname -m)" in
        arm64) note "macOS $version on Apple Silicon" ;;
        x86_64) note "macOS $version on Intel. Sotto should build, but it is only tested on Apple Silicon." ;;
        *) fail "Unsupported CPU architecture: $(uname -m)" ;;
    esac
}

check_xcode() {
    if ! xcodebuild -version >/dev/null 2>&1; then
        if [[ -d /Applications/Xcode.app ]]; then
            fail "Xcode is installed but not selected. Run:
    sudo xcode-select --switch /Applications/Xcode.app
then run this script again."
        fi
        fail "Sotto needs the full Xcode app, not only the Command Line Tools.
    Install Xcode $min_xcode or newer from the App Store: https://apps.apple.com/app/xcode/id497799835
    Open it once to finish setup, then run this script again."
    fi

    local xcode_version
    xcode_version="$(xcodebuild -version | awk 'NR == 1 {print $2}')"
    (( ${xcode_version%%.*} >= min_xcode )) ||
        fail "Sotto needs Xcode $min_xcode or newer. Found Xcode $xcode_version."
    note "Xcode $xcode_version"

    if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
        fail "Xcode has not finished its first launch setup. Open Xcode once, or run:
    sudo xcodebuild -runFirstLaunch"
    fi

    # The MLX packages compile Metal shaders. Recent Xcode versions ship the Metal compiler separately.
    if ! xcrun metal --version >/dev/null 2>&1; then
        step "Installing Apple's Metal toolchain (one time)"
        xcodebuild -downloadComponent MetalToolchain
    fi

    command -v git >/dev/null || fail "git is missing. It comes with Xcode; reopen Xcode once to install it."
}

# Fails unless every component of the path below $HOME is a real folder (or missing), not a symlink,
# so the cache cleanup below can never follow a link somewhere else.
refuse_symlinks() {
    local path="$1" part=""
    local rest="${path#"$HOME"/}"
    part="$HOME"
    local IFS=/
    for name in $rest; do
        part="$part/$name"
        [[ ! -L "$part" ]] || fail "$part is a symlink. Remove it or move it aside, then run this script again."
    done
}

# Clones or updates the channel's branch into its own cache folder. The marker file proves this script
# created the folder, so local edits there may be discarded on update and the folder may be removed.
fetch_source() {
    local branch="$1" source_dir="$2"
    local marker="$source_dir/$cache_marker"
    refuse_symlinks "$source_dir"
    if [[ -e "$source_dir" && ! -f "$marker" ]]; then
        fail "$source_dir exists but was not created by this script. Move it aside, then run this script again."
    fi
    if [[ -d "$source_dir/.git" ]]; then
        step "Updating source ($branch)"
        git -C "$source_dir" remote set-url origin "$repo_url"
        git -C "$source_dir" fetch --quiet --depth 1 origin "$branch"
        git -C "$source_dir" reset --quiet --hard FETCH_HEAD
    else
        step "Downloading source ($branch)"
        rm -rf "$source_dir"
        mkdir -p "$(dirname "$source_dir")"
        git clone --quiet --depth 1 --branch "$branch" "$repo_url" "$source_dir"
        touch "$marker"
    fi
    note "$(git -C "$source_dir" log -1 --format='%h %s')"
}

# Prints the bundle ID of an app, or nothing.
bundle_id_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Whether `dest` may be replaced: nothing is there, or this channel's app is, owned by this user and not a symlink.
replaceable() {
    [[ ! -e "$dest" && ! -L "$dest" ]] && return 0
    [[ ! -L "$dest" && -d "$dest" && -O "$dest" && "$(bundle_id_of "$dest")" == "$bundle_id" ]]
}

# Sets `dest`, where the app goes, and checks it can be replaced without sudo, before anything is built.
# An installed copy is updated where it is; a new one goes to /Applications when writable, else ~/Applications.
choose_destination() {
    local dir
    if [[ -n "${SOTTO_INSTALL_DIR:-}" ]]; then
        dir="$SOTTO_INSTALL_DIR"
    elif [[ "$(bundle_id_of "/Applications/$app_name.app")" == "$bundle_id" ]]; then
        dir=/Applications
    elif [[ "$(bundle_id_of "$HOME/Applications/$app_name.app")" == "$bundle_id" ]]; then
        dir="$HOME/Applications"
    elif [[ ! -e "/Applications/$app_name.app" && ! -L "/Applications/$app_name.app" && -w /Applications ]]; then
        dir=/Applications
    else
        dir="$HOME/Applications"
    fi
    mkdir -p "$dir" 2>/dev/null || fail "Could not create $dir."
    [[ -w "$dir" ]] || fail "$dir is not writable. Set SOTTO_INSTALL_DIR to a folder you own, for example ~/Applications."
    dest="$dir/$app_name.app"
    replaceable || fail "$dest is not $app_name ($bundle_id) owned by this account, or it is a symlink.
    Move it away, or set SOTTO_INSTALL_DIR to another folder, then run this script again."
}

# Prints the PIDs whose executable is exactly this path. ps prints the full executable path,
# and the comparison is a plain string match, not a pattern.
pids_running() {
    local exe="$1" pid comm
    ps -axo pid=,comm= | while read -r pid comm; do
        [[ "$comm" == "$exe" ]] && echo "$pid"
    done
    return 0
}

# Prints the PIDs of other copies of the same executable name that run from a different path.
other_copies() {
    local exe="$1" pid comm
    local name="${exe##*/}"
    ps -axo pid=,comm= | while read -r pid comm; do
        [[ "$comm" != "$exe" && "$comm" == */Contents/MacOS/"$name" ]] && echo "$pid"
    done
    return 0
}

# Quits the copy that runs from this exact app bundle, waiting up to 10 seconds before sending SIGTERM.
quit_app() {
    local app_path="$1" exe_name exe pids
    [[ -f "$app_path/Contents/Info.plist" ]] || return 0
    exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist" 2>/dev/null)" || return 0
    exe="$app_path/Contents/MacOS/$exe_name"
    pids="$(pids_running "$exe")"
    [[ -n "$pids" ]] || return 0

    step "Quitting $(basename "$app_path")"
    # AppleScript picks the app by bundle ID, so it is only precise when no other copy of the app runs.
    if [[ -z "$(other_copies "$exe")" ]]; then
        osascript -e 'on run argv' -e 'tell application (item 1 of argv) to quit' -e 'end run' \
            "$app_path" >/dev/null 2>&1 || true
    else
        # shellcheck disable=SC2086  # one PID per word
        kill -TERM $pids 2>/dev/null || true
    fi
    for _ in {1..20}; do
        [[ -n "$(pids_running "$exe")" ]] || return 0
        sleep 0.5
    done
    pids="$(pids_running "$exe")"
    # shellcheck disable=SC2086
    [[ -z "$pids" ]] || kill -TERM $pids 2>/dev/null || true
}

# Renames `from` to `to`, which must not exist. macOS `mv` would move `from` into a folder that appeared at `to`
# instead of failing, so the result is checked too.
rename_to() {
    local from="$1" to="$2"
    [[ ! -e "$to" && ! -L "$to" ]] || return 1
    mv -n "$from" "$to" || return 1
    [[ -e "$to" && ! -e "$from" && ! -e "$to/$(basename "$from")" ]]
}

# Puts the staged build at `dest`. While the old copy sits in the staging folder (`backup`), any failure or
# interruption ends in `finish`, which puts it back.
swap_in() {
    replaceable || fail "$dest changed during the build and is not $app_name any more. Nothing was replaced."
    quit_app "$dest"
    replaceable || fail "$dest changed while $app_name was quitting. Nothing was replaced."
    if [[ -e "$dest" ]]; then
        backup="$stage/previous.app"
        rename_to "$dest" "$backup" || fail "Could not move the installed $app_name aside."
    fi
    rename_to "$stage/$app_name.app" "$dest" || fail "Could not install to $dest; something else is there now."
    [[ "$(bundle_id_of "$dest")" == "$bundle_id" ]] || fail "$dest does not hold $bundle_id after the move."
    backup=""
}

# Runs on every exit. An old copy still set aside goes back to `dest` if that is free; otherwise it is kept and
# its path printed. The staging folder is deleted only when nothing in it is needed any more.
finish() {
    if [[ -n "$backup" && -e "$backup" ]]; then
        if rename_to "$backup" "$dest"; then
            echo "The previous $app_name was put back at $dest." >&2
        else
            echo "The previous $app_name is kept at $backup. Move it back to $dest yourself." >&2
            return
        fi
    fi
    [[ -z "$stage" ]] || rm -rf "$stage"
}

uninstall() {
    local app_name="$1" bundle_id="$2" channel="$3"
    local found=false dir
    for dir in ${SOTTO_INSTALL_DIR:+"$SOTTO_INSTALL_DIR"} /Applications "$HOME/Applications"; do
        local app="$dir/$app_name.app"
        [[ -d "$app" && ! -L "$app" ]] || continue
        # Only remove a bundle that really is this app and belongs to this account.
        [[ "$(bundle_id_of "$app")" == "$bundle_id" ]] || {
            note "Skipping $app: it is not $bundle_id."
            continue
        }
        [[ -O "$app" ]] || {
            note "Skipping $app: it belongs to another account."
            continue
        }
        quit_app "$app"
        step "Removing $app"
        rm -rf "$app"
        found=true
    done

    local source_dir="$cache_root/$channel"
    refuse_symlinks "$source_dir"
    if [[ -f "$source_dir/$cache_marker" ]]; then
        rm -rf "${source_dir:?}"
    elif [[ -e "$source_dir" ]]; then
        note "Left $source_dir in place: this script did not create it."
    fi
    [[ "$found" == true ]] || note "$app_name is not installed."

    cat <<EOF

Settings, history and downloaded models were kept. To remove them too:
    rm -rf "$HOME/Library/Application Support/$bundle_id"
    defaults delete $bundle_id
    tccutil reset All $bundle_id
Speech models shared by Sotto and Sotto Beta live in:
    $HOME/Library/Application Support/FluidAudio
EOF
}

main() {
    local channel=stable action=install
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --beta) channel=beta ;;
            --uninstall) action=uninstall ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
        shift
    done

    local branch build_flag=()
    if [[ "$channel" == beta ]]; then
        branch=beta app_name="Sotto Beta" bundle_id=ro.andrei.Voce.beta build_flag=(--beta)
    else
        branch=main app_name=Sotto bundle_id=ro.andrei.Voce
    fi

    if [[ "$action" == uninstall ]]; then
        uninstall "$app_name" "$bundle_id" "$channel"
        exit 0
    fi

    step "Checking this Mac"
    check_system
    check_xcode

    # Know where the app goes before spending minutes on the build.
    choose_destination
    note "Will install to $dest"

    local source_dir="$cache_root/$channel" log
    fetch_source "$branch" "$source_dir"

    log="$source_dir/.build/install.log"
    mkdir -p "$(dirname "$log")"
    bash "$source_dir/scripts/build.sh" ${build_flag[@]+"${build_flag[@]}"} 2>&1 | tee "$log"
    local built
    built="$(tail -n 1 "$log")"
    [[ -d "$built" ]] || fail "The build did not produce an app. The full log is in $log"

    # Stage the new copy next to the destination before quitting anything, so a failed copy leaves the
    # running app alone. `stage` and `backup` are global so `finish` still sees them on any exit.
    stage="$(mktemp -d "$(dirname "$dest")/.sotto-install.XXXXXX")" || fail "Could not write to $(dirname "$dest")."
    backup=""
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ditto "$built" "$stage/$app_name.app" || fail "Could not copy $app_name to $(dirname "$dest")."
    step "Installing to $dest"
    swap_in

    if [[ "${SOTTO_NO_LAUNCH:-}" != 1 ]]; then
        step "Launching $app_name"
        open "$dest"
    fi

    cat <<EOF

Done. $app_name is installed at $dest.
The app is signed ad-hoc on this Mac, so after an update macOS may ask for
Microphone and Accessibility access again. If a permission switch is already on
but dictation does not paste, turn it off and on in System Settings.
EOF
}

main "$@"
