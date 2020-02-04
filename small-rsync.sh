#!/bin/bash

set -euf -o pipefail

scripts=$(cd $(dirname "$0") && pwd)

backup_dir="${1-/mnt/btrfs}"
backup_dir=$(cd "$backup_dir" && pwd)

# Subdirectory relative to $backup_dir to backup.
# Mostly for testing on a subset of filesystem.
#subdir="/home/maxim/bin/"
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
    $rsh dir825 rsync -a --del /opt/ /mmc/opt/
    #$rsh dir825 iptables -D INPUT -p tcp --dport 2222 -d 192.168.1.72 -j ACCEPT
    #$rsh dir825 iptables -D INPUT -p tcp --dport 2222 -d 192.168.1.73 -j ACCEPT
    $rsh dir825 pkill sshd
    sleep 5
    $rsh dir825 umount /opt
    $rsh dir825 mount -o bind /mmc/opt /opt
    $rsh dir825 /opt/sbin/fsck.ext2 -y -C 0 /dev/sda1
    $rsh dir825 umount /opt
    $rsh dir825 umount /mmc
    sleep 5
    $rsh dir825 rmmod ext2
    $rsh -O exit dir825
}

trap cleanup_exit EXIT

rsh="$tmp_dir"/rsh
cat > $rsh <<'EOF'
#!/bin/sh
exec sudo -i -u maxim ssh -S/tmp/ssh-%u-%r@%h:%p "$@"
EOF
chmod +x $rsh

rsh2="$tmp_dir"/rsh2
cat > $rsh2 <<'EOF'
#!/bin/sh
exec sudo -i -u maxim ssh -p2222 -S/tmp/ssh-%u-%r@%h:%p "$@"
EOF
chmod +x $rsh2

cleanup=false
if ! diff -q "$tmp_dir"/started "$tmp_dir"/finished; then
    # Delete out-of-date contents at destination if last backup didn't
    # finish cleanly.
    cleanup=true
fi

check_contents=false

$rsh dir825 insmod ext2 || true
$rsh dir825 mount /dev/sda1 /opt

$rsh dir825 /opt/bin/sed -i -e "/^sshd/d" /tmp/etc/passwd
echo "sshd:x:111:111:SSHD:/:/bin/false" | $rsh dir825 tee -a /tmp/etc/passwd
$rsh dir825 /opt/sbin/sshd -p 2222
#$rsh dir825 iptables -I INPUT 7 -p tcp --dport 2222 -d 192.168.1.72 -j ACCEPT
#$rsh dir825 iptables -I INPUT 7 -p tcp --dport 2222 -d 192.168.1.73 -j ACCEPT

cat <<'EOF' | $rsh2 dir825 sh -c "cat > /opt/etc/e2fsck.conf"
[scratch_files]
directory = /opt/e2fsck
EOF
$rsh2 dir825 rm -rf /opt/e2fsck/
$rsh2 dir825 mkdir /opt/e2fsck
$rsh2 dir825 /opt/sbin/fsck.ext2 -y -C 0 /dev/sda2 || check_contents=true
$rsh2 dir825 mount /dev/sda2 /mmc

cat <<'EOF' | $rsh dir825 sh -c "cat > /opt/bin/myrsync"
#!/bin/sh
echo 1000 > /proc/$$/oom_score_adj
exec rsync "$@"
EOF
$rsh2 dir825 chmod +x /opt/bin/myrsync

date > "$tmp_dir"/started

if $cleanup; then
    $rsh2 dir825 "cd /mmc$subdir; find -type d -print0" \
	| xargs -0 -i@ "$scripts/small-rsync-filter.sh" "@" \
	| parallel --recend '\0' -0 --pipe -j1 -u --block 1M \
		   rsync --delete --delete-missing-args --existing --ignore-existing \
		   -0 -aP --numeric-ids --files-from=- \
		   -e $rsh2 --rsync-path=myrsync \
		   "$backup_dir$subdir" "dir825:/mmc$subdir" || true
fi

rsync_cleanup_opts=""
if $check_contents; then
    rsync_cleanup_opts="--ignore-times"
fi

(cd "$backup_dir$subdir"; find -type f -print0) \
    | parallel --recend '\0' -0 --pipe -j1 -u --block 1M \
	       rsync $rsync_cleanup_opts \
	       -0 -aP --numeric-ids --files-from=- \
	       -e $rsh2 --rsync-path=myrsync \
	       "$backup_dir$subdir" "dir825:/mmc$subdir"

cp "$tmp_dir"/started "$tmp_dir"/finished
