#!/bin/bash

set -euf -o pipefail

backup_dir="${1-/mnt/btrfs/snapshots}"
backup_dir=$(cd "$backup_dir" && pwd)

remote="macmini.root"
remote_dir="/mnt/btrfs"

# Subdirectory relative to $backup_dir to backup.
# Mostly for testing on a subset of filesystem.
#subdir="/@home/maxim/bin/"
subdir="/"

tmp_dir="$backup_dir/.backup"

mkdir -p "$tmp_dir"

exec 1>"$tmp_dir"/log 2>&1
set -x

exec 200>"$tmp_dir"/lock
flock -n 200 || exit 0

cleanup_exit()
{
    set +e

    for i in $(cd "$tmp_dir"; find . -maxdepth 1 -type d ! -path . \
		   | sed -e "s#^\./##"); do
	btrfs subvolume delete "$tmp_dir/$i"
    done

    ssh $remote umount $remote_dir
}

trap cleanup_exit EXIT

cleanup=false
if ! diff -q "$tmp_dir"/started "$tmp_dir"/finished; then
    # Delete out-of-date contents at destination if last backup didn't
    # finish cleanly.
    cleanup=true
fi

check_contents=false

ssh $remote mount $remote_dir

date > "$tmp_dir"/started

# Walk through snapshots named "@<subdir>.<date>T<time>" starting with
# the oldest snapshots first.  Create a copy of the oldest snapshot, which
# will be rsync'ed to $remote.
declare -A done_subdirs
for i in $(cd "$backup_dir"; find . -maxdepth 1 -type d ! -path . \
	       | sed -e "s#^\./##" | sort -t. -k2); do
    src_subdir="$i"
    i=$(echo "$i" | sed -e "s/^\([^\.]*\)\..*/\1/")
    if [ x"$i" = x"" ] || [ x"${done_subdirs[$i]-}" = x"1" ]; then
	continue
    fi

    btrfs subvolume snapshot -r "$backup_dir/$src_subdir" "$tmp_dir/$i" &
    if wait $!; then
	done_subdirs[$i]=1
    fi
done

cd "$tmp_dir"

cleanup_opts="--dry-run"
if $cleanup; then
    cleanup_opts=""
fi
# --existing delays transfer of new files till the main sync below.
# --ignore-existing delays update of files till the main sync below.
rsync $cleanup_opts \
    --delete --existing --ignore-existing \
    -azP --numeric-ids \
    ".$subdir" "$remote:$remote_dir$subdir" > cleanup.log || true

check_opts=""
if $check_contents; then
    check_opts="--ignore-times"
fi

rsync $check_opts \
      -azP --numeric-ids \
      ".$subdir" "$remote:$remote_dir$subdir"

cp "$tmp_dir"/started "$tmp_dir"/finished
