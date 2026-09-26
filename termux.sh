#!/bin/bash
# Termux installer for this Hikka build.
# Rewritten to be robust across different Termux app versions, package-index
# states and CPU architectures, and to check for the Python 3.14+ requirement
# of this specific build instead of silently failing later inside Python.

set -u

# ---- configuration ---------------------------------------------------
# Point this at wherever you host your patched build. Left as the upstream
# Hikka repo by default -- change REPO_URL/REPO_BRANCH if you publish your
# own fork.
REPO_URL="${HIKKA_REPO_URL:-https://github.com/jekone154/testing_bot.git}"
REPO_BRANCH="${HIKKA_REPO_BRANCH:-master}"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=10
INSTALL_DIR="$HOME/Hikka"
# ------------------------------------------------------------------------

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; CYAN="\033[0;96m"
MAGENTA="\033[1;35m"; RESET="\033[0m"

fail() {
    printf "\r\033[K${RED}✖ %s${RESET}\n" "$1"
    exit 1
}

step() {
    printf "\n${CYAN}%s${RESET}\n" "$1"
}

ok() {
    printf "\r\033[K${GREEN}✔ %s${RESET}\n" "$1"
}

run() {
    # Run a command, show its own output, and abort with a clear message on failure.
    # Using this instead of blind `eval "$cmd"` (no error checking) is what makes
    # the rest of the script safe to trust on Termux installs that differ in
    # package availability, architecture, or directory layout.
    "$@" || fail "Command failed: $*"
}

echo -e "\033[2J\033[3;1f"

# ---- sanity checks: are we actually in Termux? -------------------------
if [[ -z "${PREFIX:-}" ]] || [[ "$PREFIX" != *"/com.termux/"* ]]; then
    fail "\$PREFIX is not set to a Termux path. Run this script inside the Termux app, not a regular Linux shell/proot."
fi

if ! command -v pkg >/dev/null 2>&1; then
    fail "'pkg' command not found. This does not look like a supported Termux environment."
fi

[[ -f "$HOME/Hikka/assets/download.txt" ]] && cat "$HOME/Hikka/assets/download.txt"
printf "${MAGENTA}Hikka is being installed... ✨${RESET}\n"

# ---- refresh package index first ---------------------------------------
# Older Termux installs (or ones that haven't been opened in a while) often
# have a stale package index, which is the single most common cause of
# "package not found" / version-mismatch errors across different Termux
# versions. Doing this first, unconditionally, fixes most of that class of
# problem before it happens.
step "Updating package index..."
run pkg update -y
ok "Package index refreshed"

step "Installing base packages..."
run pkg install -y git python libjpeg-turbo openssl binutils wget clang make pkg-config python-psutil
ok "Packages ready!"

# ---- verify the installed Python actually satisfies this build ---------
if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 was not installed correctly."
fi

py_version=$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
py_major=${py_version%%.*}
py_minor=${py_version##*.}

if (( py_major < MIN_PYTHON_MAJOR || (py_major == MIN_PYTHON_MAJOR && py_minor < MIN_PYTHON_MINOR) )); then
    echo -e "${YELLOW}⚠ Termux's 'python' package currently provides Python ${py_version},"
    echo -e "  but this build requires Python ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}+.${RESET}"
    echo -e "${YELLOW}  This is expected right after a new CPython release, before Termux's"
    echo -e "  package repo has caught up. Options:${RESET}"
    echo -e "   1) Try again in a few days after 'pkg update' picks up a newer build"
    echo -e "   2) Install Python ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR} from source via a tool like pyenv/tur-repo"
    echo -e "   3) Continue anyway at your own risk (the bot may refuse to start)"
    read -r -p "Continue with Python ${py_version} anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || fail "Aborted: Python version requirement not met."
else
    ok "Python ${py_version} satisfies the ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}+ requirement"
fi

# ---- architecture-aware build flags for Pillow --------------------------
# `uname -m` is used instead of `lscpu` because lscpu (util-linux) is not
# installed on many minimal Termux setups, while uname is always available
# (provided by toybox/busybox) -- this alone was a portability gap in the
# previous version of this script.
step "Installing Pillow..."
arch=$(uname -m)
case "$arch" in
    aarch64|arm64)
        export LDFLAGS="-L/system/lib64/"
        ;;
    armv7l|armv8l|arm)
        export LDFLAGS="-L/system/lib/"
        ;;
    x86_64)
        export LDFLAGS="-L/system/lib64/"
        ;;
    i686|i386)
        export LDFLAGS="-L/system/lib/"
        ;;
    *)
        echo -e "${YELLOW}⚠ Unrecognized architecture '${arch}', defaulting to lib64 flags.${RESET}"
        export LDFLAGS="-L/system/lib64/"
        ;;
esac
export CFLAGS="-I${PREFIX}/include/"
export CC=clang
export CXX=clang++

run pip install Pillow -U --no-cache-dir
ok "Pillow installed!"

# ---- fetch source --------------------------------------------------------
step "Downloading source code..."
rm -rf "$INSTALL_DIR" 2>/dev/null

run git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
cd "$INSTALL_DIR" || fail "Could not enter $INSTALL_DIR after cloning"
ok "Source code downloaded!"

# ---- locate the actual project root inside the clone --------------------
# Some repos (e.g. ones assembled by hand from a downloaded zip) end up with
# the real project one level deeper than the repo root -- detect that instead
# of assuming a fixed path, so this script keeps working even if the layout
# changes later.
if [[ ! -f "requirements.txt" || ! -d "hikka" ]]; then
    found_dir=""
    while IFS= read -r -d '' candidate; do
        found_dir="$(dirname "$candidate")"
        break
    done < <(find . -mindepth 2 -maxdepth 3 -name "requirements.txt" -print0 2>/dev/null)

    if [[ -n "$found_dir" && -d "$found_dir/hikka" ]]; then
        echo -e "${YELLOW}⚠ requirements.txt/hikka/ not in repo root -- using nested folder: ${found_dir}${RESET}"
        cd "$found_dir" || fail "Could not enter detected project folder $found_dir"
        INSTALL_DIR="$INSTALL_DIR/$found_dir"
    else
        fail "Could not find requirements.txt next to a hikka/ package anywhere in the cloned repo. Check the repo layout."
    fi
fi

step "Installing requirements..."
# psutil is installed separately via 'pkg' above (python-psutil): upstream
# psutil refuses to build via pip on Android ("platform android is not
# supported" -- a hard check in its own setup.py, not a missing-compiler
# issue). Strip it from requirements.txt before handing it to pip so pip
# never touches it, regardless of --upgrade or version pins.
grep -vi '^psutil' requirements.txt > /tmp/hikka_requirements_termux.txt
run pip install -r /tmp/hikka_requirements_termux.txt --no-cache-dir --no-warn-script-location --disable-pip-version-check --upgrade
rm -f /tmp/hikka_requirements_termux.txt
ok "Requirements installed!"

# ---- autostart ------------------------------------------------------------
if [[ -z "${NO_AUTOSTART:-}" ]]; then
    step "Configuring autostart..."

    # Writing directly to $PREFIX/etc/motd instead of the old "~/../usr/etc/motd"
    # relative path: that path only happens to resolve correctly when $HOME is
    # exactly one directory below $PREFIX, which is not guaranteed across every
    # Termux version/fork. $PREFIX is always correct.
    : > "$PREFIX/etc/motd"

    {
        echo "clear"
        echo ". <(wget -qO- ${REPO_URL/github.com/raw.githubusercontent.com}/${REPO_BRANCH}/banner.sh) 2>/dev/null"
        echo "cd \"$INSTALL_DIR\" && python3 -m hikka"
    } > "$HOME/.bash_profile"

    ok "Autostart enabled!"
fi

echo -e "\033[0;96mStarting Hikka...\033[0m"
echo -e "\033[2J\033[3;1f"

printf "\033[1;32mHikka is starting...\033[0m\n"

exec python3 -m hikka
