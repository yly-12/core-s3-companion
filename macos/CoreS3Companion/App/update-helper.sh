#!/bin/sh
# Invoked with positional arguments, never shell-interpolated download metadata.
set -eu
umask 077

parent_pid=$1
target=$2
staged=$3
work_dir=$4
result=$5
candidate="${target%.app}.update-$(/usr/bin/basename "$work_dir").app"
backup="${target%.app}.backup-$(/usr/bin/basename "$work_dir").app"
old_moved=false
new_moved=false
finished=false
candidate_created=false

write_result() {
    /usr/bin/printf '%s\n' "$1" > "$result.tmp"
    /bin/mv -f "$result.tmp" "$result"
}

cleanup() {
    code=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$finished" != true ]; then
        reopen="$target"
        recovery_failed=false
        if [ "$new_moved" = true ]; then /bin/rm -rf "$target"; fi
        if [ "$old_moved" = true ]; then
            if [ -e "$target" ] || [ -L "$target" ] || ! /bin/mv "$backup" "$target"; then
                recovery_failed=true
                reopen="$backup"
            fi
        fi
        if [ "$recovery_failed" = true ]; then
            write_result "error:更新回滚失败，旧应用仍保留在 ${backup}。请从该位置恢复应用。"
        else
            write_result 'error:更新安装或重启失败，已保留或恢复旧版本。请重试更新。'
        fi
        if ! /bin/kill -0 "$parent_pid" 2>/dev/null; then
            /usr/bin/open -n "$reopen" || true
        fi
    fi
    if [ "$candidate_created" = true ]; then /bin/rm -rf "$candidate"; fi
    /bin/rm -rf "$work_dir"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Refuse to overwrite pre-existing transaction paths or an invalid destination.
if [ ! -d "$target/Contents" ] || [ ! -d "$staged/Contents" ]; then exit 1; fi
if [ -e "$candidate" ] || [ -e "$backup" ] || [ -L "$candidate" ] || [ -L "$backup" ]; then exit 1; fi
if [ -L "$target" ] || [ -L "$staged" ]; then exit 1; fi
candidate_created=true
/usr/bin/ditto "$staged" "$candidate"
/usr/bin/touch "$work_dir/ready"

attempt=0
while /bin/kill -0 "$parent_pid" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -le 60 ] || exit 1
    /bin/sleep 1
done

/bin/mv "$target" "$backup"
old_moved=true
/bin/mv "$candidate" "$target"
new_moved=true
/usr/bin/open -n "$target"
write_result 'ok'
finished=true
/bin/rm -rf "$backup"
