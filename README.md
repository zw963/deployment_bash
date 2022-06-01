# Because GFW from china, this project only updated on https://gitlab.com/zw963/deployment_bash

## Use deployment_bash deploy a app to remote VPS.


Following is a example will explain what we did and what you want.

The purpose of this script is to deploy a app located in github, which
deploy a lightweight SOCKS5 forward proxy to Ubuntu or CentOS.

original deploy code is [here](https://github.com/zw963/asuswrt-merlin-transparent-proxy/blob/master/deploy_ss_to_vps).

```sh
#!/bin/sh

# download this code, and eval.
self="$(curl https://raw.githubusercontent.com/zw963/deployment_bash/v0.2.2/deploy_start.sh)" && eval "$self"

# target is necessory, for use internal.
# any environemnt variable expect availabe in remote VPS deployment process
# need declar with export, e.g. `export abc=100`, only `abc=100`, abc not available remote.
export target=$1

# copy command copy a local file to remote, if VPS target directory not exist, will created automatically.
# copy support rsync options, e.g.
# copy ss-server/config.json /etc/shadowsocks/config.json -u
# will override remote file only local is newer.

copy ss-server/config.json /etc/shadowsocks/config.json


# this line is necessory, after this line, will execute in remote ssh shell.
deploy_start

# # Following can be any valid bash code which will be execute on remote VPS ssh shell.

# replace_string 'origin' 'new' file
# more function available, see source code.
replace_string 'mypassword' "你的密码" /etc/shadowsocks/config.json

cat <<'HEREDOC' > /etc/sysctl.d/98-shadowsocks.conf
fs.file-max=51200

net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.netdev_max_backlog=250000
net.core.somaxconn=4096

net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_tw_recycle=0
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200
net.ipv4.ip_local_port_range=10000 65000
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=5000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mem=25600 51200 102400
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_congestion_control=hybla
HEREDOC

# package list support is limited, will add more later
# if you want, please let me know.
package compile-tools pcre-devel asciidoc xmlto mbedtls-devel libsodium-devel udns-devel libev-devel haveged

# download_and_extract is for extract files from a remote url.
[ -d shadowsocks-libev-3.0.8 ] || download_and_extract https://github.com/shadowsocks/shadowsocks-libev/releases/download/v3.0.8/shadowsocks-libev-3.0.8.tar.gz

# daemon is use systemctl to wrapper process.
# daemon 'name' 'full path to run'

cd shadowsocks-libev-3.0.8/ &&
    configure shadowsocks &&
    make &&
    make install-strip &&
    daemon shadowsocks '/usr/bin/ss-server -u --fast-open -c /etc/shadowsocks/config.json'

server_port=$(cat /etc/shadowsocks/config.json |grep 'server_port"' |grep -o '[0-9]*')
# use to expose a port in server.
expose_port $server_port
```
