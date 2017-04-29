#!/bin/bash
# Imports and applies commits from upstream aports on modified packages (ABS/AUR version)
# Note: needs asp (http://github.com/falconindy/asp) and my .files (http://github.com/Orochimarufan/.files)
# (c) 2015-2017 Taeyeon Mori

# AUR configuration from .files
. "${DOTFILES-$HOME/.files}/etc/aur.conf"

# Colors
C_PKGNAM=36
C_PKGMSG=33
C_ERRMSG=31
C_PROMPT=33

# Working Directory
WORKING_DIR=${TMPDIR-/tmp}/pkg-apply-upstream


# Helper functions
# =========================================================
# Message formatting
FMT_PKGNAME="\033[${C_PKGNAM}m%s\033[-MSGCOLOR-m"

cmsg() {
    colr="$1"
    shift
    fmt="`echo "$1" | sed -e "s/\\[-MSGCOLOR-m/\\[${colr}m/g"`"
    shift
    printf "\033[${colr}m$fmt\033[0m\n" "$@"
}

msg() {
    cmsg $C_PKGMSG "$@"
}

err() {
    cmsg $C_ERRMSG "$@"
}

# Run something in subdir
run_in() {
    # run_in DIR CMD...
    local _OLDPWD
    local _RT
    _OLDPWD="$OLDPWD"
    cd "$1"
    shift
    "$@"
    _RT=$?
    cd "$OLDPWD"
    OLDPWD="$_OLDPWD"
    return $_RT
}

# Ask a yes/no question
yesno() {
    while true; do
        printf "\033[${C_PROMPT}m%s (y/n)\033[0m " "$1"
        read R
        case $R in
            [Yy]*) return 0;;
            [Nn]*) return 1;;
        esac
    done
}


# Parse commandline
# =========================================================
pkgs=()
exclude=()

_arg_value=
process_arg() {
    if [ -n "$_arg_value" ]; then
        case "$_arg_value" in
            -e|--exclude)
                exclude+=("`echo "$1" | tr , ' '`");;
        esac
        _arg_value=
    else
        case "$1" in
            --help)
                echo "PKGBUILD upstream synchronizer"
                echo "    (c) 2015-2017 Taeyeon Mori"
                echo
                echo "Usage: $0 --help"
                echo "       $0 [package-names ...]"
                echo "       $0 --exclude [package-names,...]"
                exit 0;;
            -e|--exclude)
                _arg_value=$1;;
            *)
                pkgs+=("$1");;
        esac
    fi
}

for cx in "$@"; do
  case "$cx" in
    --*)
      process_arg "$cx";;
    -*)
      for c in `echo "${cx:1}" | grep -o .`; do
        process_arg "-$c"
      done;;
    *)
      process_arg "$cx";;
  esac
done


# Working Directory
# =========================================================
if [ -e "$WORKING_DIR" ]; then
    err "Somebody is already running this script which should not be used concurrently."
    err "If that is not the case, delete $WORKING_DIR and re-run it."
    exit 1
else
    mkdir "$WORKING_DIR"
fi

# Proper cleanup
kbd_int() {
    err "Keyboard Interrupt"
    [ -n "`ls "$WORKING_DIR"`" ] && git am --abort # assume git am was in progress
    rm -r "$WORKING_DIR"
    exit 255
}

trap kbd_int SIGINT


# Find Packages
# =========================================================
if [ -z "$pkgs" ]; then
    pkgs=("`find . -mindepth 2 -maxdepth 2 -type f -name UPSTREAM -printf '%h\n'`")
fi


# Process Packages
# =========================================================
for pkg in $pkgs; do
    pkg="`basename "$pkg"`"

    for excl in "${exclude[@]}"; do
        if [ "$pkg" = "$excl" ]; then
            warn "Skipping $pkg (Excluded on commandline)"
            continue
        fi
    done

    if ! [ -e "$pkg/PKGBUILD" ]; then
        err "Not an Arch Package: '$FMT_PKGNAME'" $pkg
        continue
    fi

    upstream_type=""
    upstream_name=""

    if [ -e "$pkg/UPSTREAM" ]; then
        if grep -q : "$pkg/UPSTREAM"; then
            upstream_type="`cut -d: -f1 $pkg/UPSTREAM`"
            upstream_name="`cut -d: -f2 $pkg/UPSTREAM`"
            upstream_rev="`cut -d: -f3 $pkg/UPSTREAM`"
        else
            upstream_rev="`cat $pkg/UPSTREAM`"
        fi
    else
        err "Could not determine upstream rev from UPSTREAM. Please put '[<AUR/ABS>:<name>:]<git rev>' into '$pkg/UPSTREAM'."
        continue
    fi

    if [ -z "$upstream_name" ]; then
        upstream_name=$pkg
    fi

    if [ -z "$upstream_type" ]; then
        if asp list-repos $upstream_name >/dev/null 2>&1; then
            upstream_type=ABS
        else
            upstream_type=AUR
        fi
    fi

    if ! git ls-files --error-unmatch "$pkg" >/dev/null 2>&1; then
        err "Package '$FMT_PKGNAME' is not being tracked!" $pkg
        continue
    fi

    if echo "$upstream_type" | grep -qi "ABS"; then
        upstream_type=ABS
        upstream_dir="$ABSDEST/$upstream_name"
        apply_options="-p2"
    else
        upstream_type=AUR
        upstream_dir="$AURDEST/$upstream_name"
        apply_options="-p1"
    fi

    msg "Package '$FMT_PKGNAME' (from %s: $FMT_PKGNAME):" $pkg $upstream_type $upstream_name

    if ! [ -e "$upstream_dir" ]; then
        if [ "$upstream_type" = "ABS" ]; then
            run_in "$ABSDEST" asp checkout $upstream_name
        else
            aur.sh -X $upstream_name
        fi
    else
        if [ "$upstream_type" = "ABS" ]; then
            run_in "$ABSDEST" asp update "$upstream_name"
        fi
        run_in "$upstream_dir" git pull
    fi

    if ! [ -e "$upstream_dir" ]; then
        err "Upstream package '$FMT_PKGNAME' for '$FMT_PKGNAME' not found in (local) %s." $upstream_name $pkg $upstream_type
        continue
    fi

    run_in "$upstream_dir" git format-patch $upstream_rev...HEAD -o "$WORKING_DIR" -- trunk

    if [ -z "`ls "$WORKING_DIR"`" ]; then
        echo "No changes."
        continue
    fi

    if yesno "Apply patches?"; then
        git am $apply_options --directory="$pkg" --reject "$WORKING_DIR"/*
        APPLY_RESULT=$?

        if [ $APPLY_RESULT -ne 0 ]; then
            cmsg 34 "NOTE: Dropping into a embedded shell. Use \`resolved\` or \`abort\` to return."
            cmsg 34 "NOTE: You can use \`edit\` to edit files in vim. It will automatically show any rejected hunks in an additional buffer."
            cmsg 34 "NOTE: The edited file will be added to the git index after vim is closed. \`e\` is short for 'edit PKGBUILD'."
            cmsg 34 "NOTE: Use \`sum\` to update the checksums. \`fin\` can be used to stage all modifications and commit. \`sf\` combines both."
            cmsg 34 "NOTE: \`st\` is short for git status. At this time, the prompt doesn't support history or completion :'("
        fi

        while [ $APPLY_RESULT -ne 0 ]; do
            (
                cd "$pkg"
                git status --short
                resolved() {
                    exit 2
                }
                abort() {
                    exit 1
                }
                skip() {
                    exit 3
                }
                edit() {
                    f=$1
                    shift
                    if [ -e "$f.rej" ]; then
                        vim "$f" -O "$f.rej" "$@"
                    else
                        vim "$f" "$@"
                    fi
                    git add "$f"
                }
                e() {
                    edit PKGBUILD
                }
                sum() {
                    updpkgsums
                    git add PKGBUILD
                }
                fin() {
                    git add -u
                    resolved
                }
                st() {
                    git status
                }
                sf() {
                    sum
                    fin
                }
                while true; do
                    echo -en "\033[${C_PROMPT}m(AM) $PWD$ \033[0m"
                    read _cmd
                    eval "$_cmd"
                done
            )
            RT=$?

            if [ $RT -eq 1 ]; then
                git am --abort
                break
            elif [ $RT -ge 2 ]; then
                find "$pkg" -name '*.rej' -delete
                [ $RT -eq 3 ] && what=skip || what=continue
                git am --$what
                APPLY_RESULT=$?
            else
                echo "WARNING: Exit the (AM) prompt with either \`resolved\` or \`abort\`"
            fi
        done

        if [ $APPLY_RESULT -eq 0 ]; then
            printf "%s:%s:" $upstream_type $upstream_name >"$pkg/UPSTREAM"
            run_in "$upstream_dir" git rev-parse --verify HEAD >>"$pkg/UPSTREAM"
            git add "$pkg/UPSTREAM"
            git commit -m "$pkg: Apply $upstream_name @`run_in "$upstream_dir" git rev-parse --short HEAD` from $upstream_type"
        fi
    fi

    rm "$WORKING_DIR"/*
done

rmdir "$WORKING_DIR"

