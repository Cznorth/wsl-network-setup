#!/bin/sh
# Windows 的 rewsl.cmd 经 ssh 调用(authorized_keys 里用 command= 强制到本脚本,该密钥只能进容器)。
# 路径来自 $SSH_ORIGINAL_COMMAND 或 $1;Windows 路径(如 D:/proj)映射成 /mnt/d/proj,不存在则落到 /work。
C=wslproxy-srv-residential-proxy-1
p=${SSH_ORIGINAL_COMMAND:-${1:-}}
# 可选后缀 "路径|claude 参数...":直接运行官方 claude;只放行 claude
cmd=
case "$p" in *\|claude*) cmd=${p#*|}; p=${p%%|*} ;; esac
p=${p#\'}; p=${p%\'}
dir=/work
case "$p" in
  [A-Za-z]:*) l=$(printf %s "${p%%:*}" | tr A-Z a-z); t="/mnt/$l${p#?:}"
              docker exec "$C" test -d "$t" && dir=$t ;;
esac
[ -n "$cmd" ] && exec docker exec -it -e LANG=C.UTF-8 -e LC_ALL=C.UTF-8 -w "$dir" "$C" bash -lc "$cmd"
exec docker exec -it -e LANG=C.UTF-8 -e LC_ALL=C.UTF-8 -w "$dir" "$C" bash -l
