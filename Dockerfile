ARG UBUNTU_IMAGE=docker.m.daocloud.io/library/ubuntu:24.04
FROM ${UBUNTU_IMAGE}

ARG GOST_VERSION=2.12.0
ARG APT_MIRROR=mirrors.aliyun.com
ARG GOST_DOWNLOAD_BASE=https://ghfast.top/https://github.com/ginuerzh/gost/releases/download
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

RUN case "${TARGETARCH:-amd64}" in \
         arm64) apt_path=ubuntu-ports ;; \
         *) apt_path=ubuntu ;; \
    esac \
    && if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
         sed -i \
           -e "s#https\?://archive.ubuntu.com/ubuntu\(/\?\)#http://${APT_MIRROR}/${apt_path}/#g" \
           -e "s#https\?://security.ubuntu.com/ubuntu\(/\?\)#http://${APT_MIRROR}/${apt_path}/#g" \
           -e "s#https\?://ports.ubuntu.com/ubuntu-ports\(/\?\)#http://${APT_MIRROR}/ubuntu-ports/#g" \
           /etc/apt/sources.list.d/ubuntu.sources; \
       fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         bash ca-certificates curl git gzip iproute2 iptables \
         iputils-ping dnsutils net-tools less nano vim-tiny \
         openssh-client procps tar python3 python3-venv jq file \
         unzip xz-utils sudo make redsocks \
    && rm -rf /var/lib/apt/lists/* \
    && case "${TARGETARCH:-amd64}" in \
         amd64) gost_arch=amd64 ;; \
         arm64) gost_arch=arm64 ;; \
         *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && { curl -k -fsSL --retry 3 \
         "${GOST_DOWNLOAD_BASE}/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${gost_arch}.tar.gz" \
         -o /tmp/gost.tgz \
       || curl -k -fsSL --retry 3 \
         "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${gost_arch}.tar.gz" \
         -o /tmp/gost.tgz; } \
    && tar -xzf /tmp/gost.tgz -C /tmp gost \
    && install -m 0755 /tmp/gost /usr/local/bin/gost \
    && rm -rf /tmp/gost /tmp/gost.tgz

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY files/dnsfwd.py /usr/local/bin/dnsfwd.py
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

EXPOSE 7893 7894
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
