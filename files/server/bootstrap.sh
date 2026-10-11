#!/bin/bash
# 在服务器上以 root 运行(由 deploy-server.sh 经 ssh 调用,代码已同步到 /opt/wslproxy)。幂等。
# 输入环境变量: WIN_USER DRIVES("c d f") TUNNEL_PUB REWSL_PUB WORKSPACE
#   阶段 prep   : 装 docker/sshfs、sshd 设置、生成 winssh 密钥、写 authorized_keys / units / .env 中非密钥部分
#   阶段 up     : 等隧道、挂盘、docker compose up
set -eu
D=/opt/wslproxy
phase=${1:?prep|up}

case "$phase" in
prep)
    export DEBIAN_FRONTEND=noninteractive
    command -v apt-get >/dev/null || { echo "仅支持 Debian/Ubuntu(apt)" >&2; exit 1; }
    if ! command -v docker >/dev/null; then curl -fsSL https://get.docker.com | sh; fi
    docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin
    command -v sshfs >/dev/null || { apt-get update -qq; apt-get install -y -qq sshfs; }
    grep -qs '^user_allow_other' /etc/fuse.conf || echo user_allow_other >> /etc/fuse.conf

    # sshd: 反向隧道端口只绑回环
    if ! sshd -T 2>/dev/null | grep -qi '^gatewayports clientspecified'; then
        cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.bak-wslproxy
        sed -i '/^\s*GatewayPorts\b/d' /etc/ssh/sshd_config
        printf '\nGatewayPorts clientspecified\n' >> /etc/ssh/sshd_config
        sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd; }
    fi

    # 服务器 -> Windows 的密钥
    mkdir -p $D/keys; chmod 700 $D/keys
    [ -f $D/keys/winssh ] || ssh-keygen -q -t ed25519 -N '' -C "wslproxy-$(hostname)-to-windows" -f $D/keys/winssh
    printf 'WIN_USER=%s\n' "$WIN_USER" > $D/keys/win.env

    # authorized_keys: 隧道密钥只能做 127.0.0.1:2222 的反向转发;rewsl 密钥只能进容器
    mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
    sed -i '/ wslproxy-tunnel-win$/d; / wslproxy-rewsl-win$/d' /root/.ssh/authorized_keys
    printf 'restrict,port-forwarding,permitlisten="127.0.0.1:2222" %s wslproxy-tunnel-win\n' "$TUNNEL_PUB" >> /root/.ssh/authorized_keys
    printf 'restrict,pty,command="%s/files/server/rewsl-enter.sh" %s wslproxy-rewsl-win\n' "$D" "$REWSL_PUB" >> /root/.ssh/authorized_keys
    chmod +x $D/files/server/rewsl-enter.sh

    # 宿主机侧 units
    cp $D/files/server/wslproxy-win@.service $D/files/server/wslproxy-winssh.socket $D/files/server/wslproxy-winssh.service /etc/systemd/system/
    systemctl daemon-reload

    # compose 的盘挂载(每盘一个 bind,rslave)
    {
        echo "services:"; echo "  residential-proxy:"; echo "    volumes:"
        for l in $DRIVES; do
            printf '      - type: bind\n        source: /mnt/win/%s\n        target: /mnt/%s\n        bind: {propagation: rslave}\n' "$l" "$l"
        done
    } > $D/compose.drives.yml
    mkdir -p "$WORKSPACE"
    { grep -Ev '^(WORKSPACE|WIN_USER|COMPOSE_FILE)=' $D/.env 2>/dev/null || true
      echo "WORKSPACE=$WORKSPACE"; echo "WIN_USER=$WIN_USER"
      echo "COMPOSE_FILE=docker-compose.server.yml:compose.drives.yml"; } > $D/.env.new
    chmod 600 $D/.env.new; mv $D/.env.new $D/.env
    cat $D/keys/winssh.pub
    ;;
up)
    cd $D
    for l in $DRIVES; do mkdir -p /mnt/win/$l; done
    systemctl enable --now wslproxy-winssh.socket >/dev/null 2>&1 || true
    # 等 Windows 反向隧道
    for i in $(seq 1 30); do
        (exec 3<>/dev/tcp/127.0.0.1/2222) 2>/dev/null && break
        [ "$i" = 30 ] && { echo "反向隧道 127.0.0.1:2222 未建立(Windows 计划任务是否在运行?)" >&2; exit 2; }
        sleep 2
    done
    # 需要 docker 网桥 192.168.64.1 存在才能监听,先起 compose 再启动 socket
    docker compose up -d --build
    systemctl restart wslproxy-winssh.socket
    for l in $DRIVES; do
        u=${l^^}   # Windows 盘符实例名用大写
        systemctl enable "wslproxy-win@$u.service" >/dev/null 2>&1
        systemctl restart "wslproxy-win@$u.service"
    done
    ;;
esac
