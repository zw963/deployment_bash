#!/bin/bash

function detect_target () {
    if [[ "$target" == localhost ]]; then
        target=$target
    elif [[ "$target" =~ [-_.[:alnum:]]+@.+ ]]; then
        target=${BASH_REMATCH[0]}
        # elif [[ "$target" =~ [a-zA-Z0-9_.]+ ]]; then
        #     # 域名
        #     target=${BASH_REMATCH[0]}
    else
        echo "\`\$target' variable must be provided in your's scripts before run scripts."
        echo 'e.g. target=localhost or target=root@123.123.123.123'
        echo 'or provide with arg, e.g. deploy_start root@123.123.123.123'
        exit
    fi
}

function extract_remote_script {
    # awk "/^[[:space:]]*$*/,EOF" |tail -n +2
    # 上面的 awk 版本在 Ubuntu 的非 GNU 版本的 awk 上不工作.
    # 下面的 sed 是不是会带来新的兼容问题？
    # 考虑使用 grep -A 来实现，兼容性应该最好，
    #但是 -A 后面只能指定一个很大的数值, 来确保显示文件后面所有的行.
    sed -n "/^[[:space:]]*$*/,\$p" |tail -n +2
}

function deploy_start {
    detect_target

    targetip=$(echo $target |cut -d'@' -f2)
    local preinstall="$(echo "$self" |extract_remote_script "export -f $FUNCNAME")
set +ue
$export_hooks
export target=$target
export targetip=$targetip
_modifier=$USER
echo '***********************************************************'
echo Remote deploy scripts is started !!
echo '***********************************************************'
set -ue
"
    local deploy_script="$preinstall$(cat $0 |extract_remote_script $FUNCNAME)"

    set +u
    if [ "$SSH_CLIENT$SSH_TTY" ]; then
        is_ssh_login=true
    else
        is_ssh_login=false
    fi
    set -u

    if ! type postinstall &>/dev/null; then
        function postinstall () { true; };
    fi
    export -f postinstall

    if ! $is_ssh_login; then
        set -u
        # 检测是否存在 bash perl
        ssh $target 'bash --version' &>/dev/null

        if [ $? != 0 ]; then
            # echo "[0m[33mremote host missing bash & perl, try to install it...[0m"
            ssh $target 'opkg install bash perl'
        fi

        ssh $target bash <<< "$deploy_script"

        if [ $? == 0 ]; then
            set +u
            postinstall
        fi

        exit 0
    fi
}

export -f deploy_start

function package_exists () {
    if [[ $(cat /etc/*-release) =~ Ubuntu|Debian ]]; then
        dpkg -l "$*"
    elif [[ $(cat /etc/*-release) =~ CentOS ]]; then
        rpm -q --quiet "$*"
    fi
}

function package_install_command () {
    if grep -qs 'Ubuntu\|Mint\|Debian' /etc/issue; then
        sudo apt-get install -y --no-install-recommends "$@"
    elif grep -qs CentOS /etc/redhat-release; then
        # if Want get centos version, use 'rpm -q centos-release'.
        sudo yum install -y "$@"
    elif grep -qs openSUSE /etc/issue; then
        sudo zypper -n --gpg-auto-import-keys in --no-recommends "$@"
    fi
}

if ! which perl &>/dev/null; then
    package_install_command perl
fi

function append () {
    sed '$a'"$*"
}

function prepend () {
    sed "1i$*"
}

function copy () {
    detect_target

    if [ "$__use_scp" ]; then
        __scp "$@"
        return $?
    fi

    # rsync only update older file.
    __rsync "$@" 2>/dev/null

    if [ $? != 0 ]; then
        # if rsync not exist, use scp
        __use_scp=true
        __scp "$@"
    fi
}

function __rsync () {
    local local_file remote_file remote_dir
    local_file=$1
    remote_file=$2
    remote_dir=$(dirname $remote_file)

    if [ ! -e "$local_file" ]; then
        echo "local file $local_file is missing ..."
        exit
    fi

    # -a 等价于: -rlptgoD, archive 模式:
    # -r --recursive,
    # -l --link, 拷贝符号链接自身, 这是没有使用 -a 的原因.
    # -p --perms 保留权限.
    # -t --times 保留修改时间.
    # -g --group 保留分组, 下面的三个选项当前 rsync 不需要.
    # -o --owner 保留 owner
    # -D 等价于: --devices --specials 保留设备文件,保留特殊文件.

    # 其他的一些选项

    # -L --copy-links
    # -P 等价于: --partial --progress
    # -v --verbose
    # -u --update, 保留比 source 新的文件, 仅仅拷贝老的文件.
    # -h --human-readable, 输出人类可读的格式信息.

    # --rsh=ssh 这是默认你省略.

    # --rsync-path 这个命令的本意是, 用来指定远程服务器的 rsync 的路径, 例如: –rsync-path=/usr/local/bin/rsync
    # 因为字符串在 shell 下被运行, 所以它可以是任何合法的命令或脚本.
    # --exclude '.*~'

    rsync -htpPvr -z -L --rsync-path="mkdir -p $remote_dir && rsync" "$local_file" $target:"$remote_file" "${@:3}"
}

function __scp () {
    local local_file remote_file
    local_file=$1
    remote_file=$2

    if [ ! -e "$local_file" ]; then
        echo "local file $local_file is missing ..."
        exit
    fi

    if [ -f "$remote_file" ]; then
        # create target file directory if not exist.
        ssh $target mkdir -p $(dirname $remote_file)
    fi

    scp -r "$local_file" $target:"$remote_file" "${@:3}"
}


function reboot_task () {
    local exist_crontab=$(/usr/bin/crontab -l)
    if ! echo "$exist_crontab" |fgrep -qs -e "$*"; then
        echo "$exist_crontab" |append "@reboot $*" |/usr/bin/crontab -
    fi
    $*
}

function systemd () {
    local service=$1
    cat > /etc/systemd/system/$1.service
    systemctl daemon-reload
    systemctl start $service
    systemctl enable $service
    systemctl status $service
}

function backup () {
    mv $* $*_bak-$(date '+%Y-%m-%d_%H:%M')
}

function daemon () {
    local name=$1
    local command=$2
    local type=${3-simple}

    # getent passwd $name || useradd $name -s /sbin/nologin

    # systemd document chinese version.
    # http://www.jinbuguo.com/systemd/systemd.service.html

    cat <<HEREDOC > /etc/systemd/system/$name.service
     [Unit]
     Description=$name Service
     After=syslog.target network.target

     [Service]
     Type=$type
     Restart=always
     LimitCORE=infinity
     LimitNOFILE=1000000
     LimitNPROC=500
     Environment=LD_LIBRARY_PATH=/usr/lib64
     ExecStart=$command
     ExecStop=/bin/kill -TERM \$MAINPID
     ExecReload=/bin/kill -HUP \$MAINPID
     PIDFile=/var/run/${name}.pid

     [Install]
     WantedBy=multi-user.target
HEREDOC

    systemctl daemon-reload
    systemctl start $name
    systemctl enable $name
    systemctl status $name
}

function daemon1 () {
    local package_name=$1
    local command="$2 "
    set +u
    local path=$3
    set -u

    if ! which killall &>/dev/null; then
        if grep -qs CentOS /etc/redhat-release; then
            # Centos 需要 psmisc 来安装 killall
            yum install -y psmisc
        fi
    fi

    [ -e /etc/rc.func ] && backup /etc/rc.func
    wget -O /etc/rc.func https://raw.githubusercontent.com/zw963/deployment_bash/master/rc.func

    cat <<HEREDOC |tee /etc/init.d/$package_name
#!/bin/sh

ENABLED=yes
PROCS=${command%% *}
ARGS="${command#* }"
PREARGS=""
DESC=\$PROCS
PATH=/opt/sbin:/opt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${path+:}${path}

. /etc/rc.func
HEREDOC

    chmod +x /etc/init.d/$package_name
    /etc/init.d/$package_name start
}

function rc_local () {
    local conf=/etc/rc.local

    fgrep -qs "$*" $conf || echo "$*" >> $conf
    chmod +x $conf && $*
}

function clone () {
    git clone --depth=5 "$@"
}

function wait () {
    echo "Waiting $* to exit ..."
    while pgrep "^$*\$" &>/dev/null; do
        echo -n '.'
        sleep 0.3
    done
    echo "$* is terminated."
}

function append_file () {
    local content regexp file
    file=$1

    if [ "$#" == 2 ]; then
        content=$2
    elif [ "$#" == 1 ]; then
        content=$(cat /dev/stdin) # 从管道内读取所有内容.
    fi
    local line_number=$(echo "$content" |wc -l)

    if [ "$line_number" == "1" ]; then
        regexp=$(echo "$content" |regexp_escape)
        set +e
        grep -s -e "^\\s*${regexp}\\s*" "$file"
    else
        set +e
        match_multiline "$content" "$(cat $file)"
    fi

    if ! [ $? == 0 ]; then
        # echo -e "\n#= Add by ${_modifier-$USER} =#" >> "$file"
        if [ -e "$file" ] && [ "$(tail -c 1 $file)" == "" ]; then
            echo -e "$content" >> "$file"
        else
            echo -e "\n$content" >> "$file"
        fi
        echo "[0m[33mAppend \`$content' into $file[0m"
    fi
}

function prepend_file () {
    local content regexp file
    file=$1

    if [ "$#" == 2 ]; then
        content=$2
    elif [ "$#" == 1 ]; then
        content=$(cat /dev/stdin) # 从管道内读取所有内容.
    fi
    local line_number=$(echo "$content" |wc -l)

    if [ "$line_number" == "1" ]; then
        regexp=$(echo "$content" |regexp_escape)
        set +e
        grep "^\\s*${regexp}\\s*" "$file"
    else
        set +e
        match_multiline "$content" "$(cat $file)"
    fi

    if ! [ $? == 0 ]; then
        content_escaped=$(echo "$content" |replace_escape)
        sed -i 1i"$content_escaped" "$file"
        echo "[0m[33mPrepend \`$content' into $file[0m"
    fi
}

# 转义一个字符串中的所有 grep 元字符.
function regexp_escape () {
    sed -e 's/[]\/$*.^|[]/\\&/g'
}

# 这是支持 replace string 存在换行, 以及各种元字符的版本.
# 详细信息,  读这个答案: https://stackoverflow.com/a/29613573/749774
function replace_escape() {
    IFS= read -d '' -r <<< "$(sed -e ':a' -e '$!{N;ba' -e '}' -e 's/[&/\]/\\&/g; s/\n/\\&/g')"
    printf %s "${REPLY%$'\n'}"
}

# 这个是保留 & 作为之前的匹配内容的版本.
function replace_escape1() {
    IFS= read -d '' -r <<< "$(sed -e ':a' -e '$!{N;ba' -e '}' -e 's/[/\]/\\&/g; s/\n/\\&/g')"
    printf %s "${REPLY%$'\n'}"
}

# 基于 perl 的 replace 函数，目的是为了解决 sed 无法很好的全文匹配的问题。
# 这几个函数的做法，是一次性读取文件所有内容作为一个字符串，再使用 PCRE 语法匹配/替换

function match_multiline() {
    escaped_regex=$(echo "$1" |sed 's#/#\\\/#g')
    result=$(echo "$2" |perl -0777 -ne "print if /${escaped_regex}/s")

    if [[ "$result" ]]; then
        return 0
    else
        return 1
    fi
}

function perl_replace() {
    local regexp=$1
    # 注意：$1 在 perl 里面是一个矢量, 因此它有 $[ 会出错，因为 perl 会认为在通过 []
    # 方法读取矢量的元素，所以记得在 placement 中 [ 也要转义。
    # 写完一定测试一下，perl 变量引用: http://www.perlmonks.org/?node_id=353259
    local replace=$2
    local escaped_replace=$(echo "$replace" |sed 's#"#\\"#g')

    # 和 sed 类似，就是 g, 表示是否全局替换，不加只替换第一个
    local replace_all_matched=$3
    # 就是 s, 新增的话, . 也匹配 new_line
    local match_newline=$4

    if [ -z "$replace_all_matched" ]; then
        globally=''
    else
        globally=' globally'
    fi

    perl -i -ne "s$regexp$replace${replace_all_matched}${match_newline}; print \$_; unless ($& eq \"\") {print STDERR \"\`\033[0;33m$&\033[0m' was replaced with \`\033[0;33m${escaped_replace}\033[0m'${globally} for \`[0m[0;34m$6[0m'!\n\"};" "$5" "$6"
}

# 为了支持多行匹配，使用 perl 正则, 比 sed 好用一百倍！
function replace_multiline () {
    local regexp=$1
    local replace=$2
    local file=$3

    # 这个 -0 必须的，-0 表示，将空白字符作为 input record separators ($/)
    # 这也意味着，它会将文件内的所有内容整体作为一个字符串一次性读取。
    # 感觉类似于 -0777 (file slurp mode) ?
    perl_replace "$regexp" "$replace" "g" "s" -0777 "$file"
}

function replace_multiline1 () {
    local regexp=$1
    local replace=$2
    local file=$3

    perl_replace "$regexp" "$replace" "" "s" -0777 "$file"
}

# 这个和 multiline 的区别仅仅在于，multi 里面 . 也匹配 newline, regex 不会
function replace_regex () {
    local regexp=$1
    local replace=$2
    local file=$3

    perl_replace "$regexp" "$replace" "g" "" -0777 "$file"
}

function replace_regex1 () {
    local regexp=$1
    local replace=$2
    local file=$3

    perl_replace "$regexp" "$replace" "" "" -0777 "$file"
}

function replace_string () {
    # 转化输入的字符串为 literal 形式
    local regexp="\\Q$1\\E"
    local replace=$2
    local file=$3

    perl_replace "$regexp" "$replace" "g" "" -0777 "$file"
}

function replace_string1 () {
    # 转化输入的字符串为 literal 形式
    local regexp="\\Q$1\\E"
    local replace=$2
    local file=$3

    perl_replace "$regexp" "$replace" "" "" -0777 "$file"
}

function update_config () {
    local config_key=$1
    local config_value=$2
    local config_file=$3
    local delimiter=${4-=}
    local regexp="^\\s*$(echo "$config_key" |regexp_escape)\b"
    local matched_line matched_line_regexp old_value old_value_regexp replaced_line group

    # only if config key exist, update it.
    if matched_line=$(grep -s "$regexp" $config_file|tail -n1) && test -n "$matched_line"; then
        matched_line_regexp=$(echo "$matched_line" |regexp_escape)
        old_value=$(echo  "$matched_line" |tail -n1|cut -d"$delimiter" -f2)

        if [[ "$old_value" =~ \"(.*)\" ]]; then
            [ "${BASH_REMATCH[1]}" ] && group="${BASH_REMATCH[1]}"
            set +ue
            replaced_line=$(echo $matched_line |sed -e "s/${old_value}/\"${group}${group+ }$config_value\"/")
            set -ue
        else
            replaced_line=$(echo $matched_line |sed -e "s/${old_value}/& $config_value/")
        fi

        regexp="^${matched_line_regexp}$"
        replace="\n#= &\n#= Above config-default value is replaced by following config value. $(date '+%Y-%m-%d %H:%M:%S') by ${_modifier-$USER}\n$replaced_line"
        replace "$regexp" "$replace" "$config_file"
        # echo "Append \`$config_value' to \`$old_value' for $config_file $matched_line"
    fi
}

function configure () {
    set +u
    if [ ! "$1" ]; then
        echo 'Need one argument to sign this package. e.g. package name.'
        exit
    fi

    ./configure --build=x86_64-linux-gnu \
                --prefix=/usr \
                --exec-prefix=/usr \
                '--bindir=$(prefix)/bin' \
                '--sbindir=$(prefix)/sbin' \
                '--libdir=$(prefix)/lib64' \
                '--libexecdir=$(prefix)/lib64/$1' \
                '--includedir=$(prefix)/include' \
                '--datadir=$(prefix)/share/$1' \
                '--mandir=$(prefix)/share/man' \
                '--infodir=$(prefix)/share/info' \
                --localstatedir=/var \
                '--sysconfdir=/etc/$1' \
                ${@:2}
}

function wget () {
    command wget --no-check-certificate --quiet -c "$@"
}

function curl () {
    command curl -sS -L "$@"
}

function download_and_extract () {
    local ext=$( basename "$1" |grep -o '\.\w*$'|cut -b2-)
    local name=$(basename "$1" |sed 's#\.tar\(\.gz\|\.bz2\|\.lzma\)\|\.tgz\|\.t\?xz\|\.zip##')
    local dest="${2-$name}"
    local strip_level="${3-1}"

    rm -rf $dest && mkdir -p $dest

    case $ext in
        gz|tgz)
            wget "$1" -O - |tar -zxvf - -C "$dest" --strip-components=${strip_level}
            ;;
        bz2)
            wget "$1" -O - |tar -jxvf - -C "$dest" --strip-components=${strip_level}
            ;;
        xz|txz)
            wget "$1" -O - |tar -Jxvf - -C "$dest" --strip-components=${strip_level}
            ;;
        zst|zstd)
            wget "$1" -O - |tar --use-compress-program zstd -xvf - -C "$dest" --strip-components=${strip_level}
            ;;
        lzma)
            wget "$1" -O - |tar --lzma -xvf - -C "$dest" --strip-components=${strip_level}
            ;;
        zip)
            local filename=$(basename $1)

            # Detect unzip if exist
            which unzip &>/dev/null || package unzip

            # 下面的代码解决的是有些 zip 解压缩后，会创建一个子目录，
            # 但是有的又不会的兼容性问题。
            set -ue
            temp_dir=/tmp/$RANDOM$RANDOM
            mkdir -p $temp_dir &&
                wget -O $temp_dir/$filename "$1" &&
                unzip $temp_dir/"$filename" -d "$temp_dir" &&
                rm "$temp_dir/$filename" &&
                shopt -s dotglob &&
                local f=("$temp_dir"/*) &&
                if (( ${#f[@]} == 1 )) && [[ -d "${f[0]}" ]] ; then
                    mv "$temp_dir"/*/* "$dest"
                else
                    mv "$temp_dir"/* "$dest"
                fi && rm -rf "$temp_dir"
            set +ue
    esac
}

function diff () {
    command diff -q "$@" >/dev/null
}

function sshkeygen () {
    ssh-keygen -t rsa -f ~/.ssh/id_rsa -N ''
}

function expose_port () {
    for port in "$@"; do
        if grep -qs 'Ubuntu\|Mint\|Debian' /etc/issue; then
            if systemctl status ufw; then
                systemctl stop ufw
                systemctl disable ufw
                # sudo ufw allow 22336/udp
                # sudo ufw allow 22336/tcp
            fi
            rc_local "iptables -I INPUT -p tcp --dport $port -j ACCEPT"
            rc_local "iptables -I INPUT -p udp --dport $port -j ACCEPT"
            echo 'no need install iptables'
        elif grep -qs CentOS /etc/redhat-release; then
            if systemctl status firewalld; then
                systemctl stop firewalld
                systemctl disable firewalld
                # if firewall-cmd --state &>/dev/null; then
                #     firewall-cmd --zone=public --add-port=$port/tcp --permanent
                #     firewall-cmd --zone=public --add-port=$port/udp --permanent
                #     firewall-cmd --reload   # 这个只在 --permanent 参数存在时, 才需要
                #     # firewall-cmd --zone=public --list-ports
                # fi
            fi

            if ! cat /etc/selinux/config |fgrep 'SELINUX=disabled'; then
                sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
                setenforce 0
            fi
        elif grep -qs openSUSE /etc/issue; then
            yast firewall services add tcpport=$port zone=EXT
        fi
    done
}

function dockerinit () {
    getent group docker || groupadd -r -g 281 docker
    dest=$1

    if ! test -f $dest/bin/docker; then
        mkdir -p $dest/bin
        mkdir -p $dest/containers
        append_file $HOME/.bashrc "PATH=$dest/bin"':$PATH'

        # 最新版 url: https://download.docker.com/linux/static/stable/x86_64/
        download_and_extract https://download.docker.com/linux/static/stable/x86_64/docker-18.09.5.tgz $dest/bin
    fi

    if ! test -f /etc/init.d/$dest; then
        daemon1 docker-daemon "$dest/bin/dockerd --data-root $dest/containers --userland-proxy=false" $dest/bin
    fi
    PATH=$dest/bin/:$PATH

    while ! docker ps &>/dev/null; do
        echo -n '.'
        sleep 1
    done
}

function package () {
    local install installed
    # for Ubuntu build-essential
    # for centos yum groupinstall "Development Tools"
    local compile_tools='gcc autoconf automake make libtool bzip2 unzip patch wget curl perl'
    local basic_tools='mlocate git coreutils binutils rsync'

    if grep -qs 'Ubuntu\|Mint\|Debian' /etc/issue; then
        sudo apt-get update
    fi

    installed=

    centos_debian_map_list="
zlib-devel zlib1g-dev
openssl-devel libssl-dev
libffi-devel libffi-dev
readline-devel libreadline-dev
libyaml-devel libyaml-dev
ncurses-devel libncurses5-dev
gdbm-devel libgdbm-dev
sqlite-devel libsqlite3-dev
gmp-devel libgmp-dev
pcre-devel libpcre3-dev
libsodium-devel libsodium-dev
udns-devel libudns-dev
libev-devel libev-dev
libevent-devel libevent-dev
mbedtls-devel libmbedtls-dev
c-ares-devel libc-ares-dev
postgresql-devel libpq-dev
postgresql postgresql-client-common
sqlite-devel libsqlite3-dev
"
    case_statement=""


    OLDIFS="$IFS" && IFS=$'\n'
    for map in $centos_debian_map_list; do
        # 用来生成 case 语句。
        case_statement="${case_statement}
${map% *})
  installed=\"\$installed ${map#* }\"
  ;;"
    done
    IFS="$OLDIFS"

    if grep -qs 'Ubuntu\|Mint\|Debian' /etc/issue; then
        # apt-file search filename
        if ! which -a sudo &>/dev/null; then
            basic_tools="$basic_tools sudo"
            append_file /etc/sudoers 'Defaults env_reset
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
root    ALL=(ALL)       ALL
'
        fi

        basic_tools="$basic_tools apt-file"
        for i in "$@"; do
            eval "
case \"$i\" in
  ${case_statement}
compile-tools)
    installed=\"\$installed $compile_tools g++ xz-utils pkg-config\"
    ;;
 *)
    installed=\"\$installed $i\"
esac
"
        done
    elif grep -qs CentOS /etc/redhat-release; then
        basic_tools="$basic_tools yum-utils epel-release"
        # centos 7 yum-cron
        # centos 8 dnf-automatic
        # systemctl enable --now dnf-automatic.timer
        for i in "$@"; do
            case "$i" in
                compile-tools)
                    installed="$installed $compile_tools gcc-c++ xz pkgconfig"
                    ;;
                apache2-utils)
                    installed="$installed httpd-tools"
                    ;;
                *)
                    installed="$installed $i"
            esac
        done
    elif grep -qs openSUSE /etc/issue; then
        basic_tools="$basic_tools"
        for i in "$@"; do
            case "$i" in
                sqlite-devel)
                    installed="$installed sqlite3-devel"
                    ;;
                openssl-devel)
                    installed="$installed libopenssl-devel"
                    ;;
                compile-tools)
                    installed="$installed $compile_tools gcc-c++ xz pkg-config"
                    ;;
                gmp-devel)
                    installed="$installed libgmp-devel"
                    ;;
                *)
                    installed="$installed $i"
            esac
        done
    fi

    for i in $basic_tools; do
        package_install_command $i
    done

    for i in $installed; do
        package_install_command $i
    done
}

function config_sysctl_for_proxy () {
    conf_file_name=${1-99-proxy.conf}

    cat <<'HEREDOC' > /etc/sysctl.d/${conf_file_name}
fs.file-max=818354

net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.netdev_max_backlog=250000
net.core.somaxconn=4096

net.ipv4.ip_forward=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=1200
net.ipv4.ip_local_port_range=10000 65000
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=5000
net.ipv4.tcp_mem=25600 51200 102400
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1

# 开启内核 fastopen, Linux 3.7 以上支持, 3.13 才默认开启.
# 等价于 echo 3 > /proc/sys/net/ipv4/tcp_fastopen
net.ipv4.tcp_fastopen=3
HEREDOC

    if kernel_version_greater_than 4.9 && modprobe tcp_bbr && lsmod | grep bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.d/${conf_file_name}
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/${conf_file_name}

        sysctl -p > /dev/null

        # test bbr is enabled
        echo 'Checking bbr support for current VPS, you may need reboot after config sysctl settings if exit here.'
        sysctl net.ipv4.tcp_available_congestion_control |grep bbr
        sysctl -n net.ipv4.tcp_congestion_control |grep bbr
    else
        sysctl -p > /dev/null
    fi
}

function install_jq () {
    wget https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -O /usr/bin/jq && chmod +x /usr/bin/jq
    # targetip=$(curl -4L api64.ipify.org)
    # signedcert=$(xray tls cert -domain="$targetip" -name="$targetip" -org="$targetip" -expire=87600h)
    # echo $signedcert | jq '.certificate[]' | sed 's/\"//g' | tee /etc/xray/self_signed_cert.pem
    # echo $signedcert | jq '.key[]' | sed 's/\"//g' |tee /etc/xray/self_signed_key.pem
}

function is_listen () {
    local port=$*
    netstat -tunl |fgrep 'LISTEN' |awk '{print $4}' |grep ":${port}$"
}

function deploy_nginx () {
    set -ue

    if [[ $(cat /etc/*-release) =~ Ubuntu|Debian ]]; then
        # 使用下面的命令查看 Ubuntu 发布版的编号
        # code_name=$(cat /etc/*-release |grep _CODENAME |cut -d'=' -f2)
        code_name=$(lsb_release -cs)

        sudo wget https://nginx.org/keys/nginx_signing.key
        sudo apt-key add nginx_signing.key

        if ! package_exists nginx; then
            if [[ $(lsb_release -d) =~ Ubuntu ]]; then
                cat <<HEREDOC | sudo tee /etc/apt/sources.list.d/nginx.list
deb https://nginx.org/packages/ubuntu/ ${code_name} nginx
deb-src https://nginx.org/packages/ubuntu/ ${code_name} nginx
HEREDOC
            else
                cat <<HEREDOC | sudo tee /etc/apt/sources.list.d/nginx.list
deb https://nginx.org/packages/debian/ ${code_name} nginx
deb-src https://nginx.org/packages/debian/ ${code_name} nginx
HEREDOC
            fi

            sudo apt-get update
            sudo apt-get install -y --no-install-recommends nginx
            sudo systemctl enable nginx
        fi

        if false && ! package_exists python-certbot-nginx; then

            # sudo snap install core; sudo snap refresh core
            # sudo snap install --classic certbot
            # sudo ln -s /snap/bin/certbot /usr/bin/certbot

            add-apt-repository ppa:certbot/certbot
            apt update
            apt install python3-certbot-nginx
            # 1. Run `sudo certbot --nginx' to configure current domain.
            # 2. Test if can renew certbot successful. `sudo certbot renew --dry-run'
            # 3. Add following crontab, will date cert first day of month.
            #    0 0 1 * * /usr/bin/certbot renew
            # more detail, check https://certbot.eff.org/

            sudo certbot certonly --nginx
        fi
    elif [[ $(cat /etc/*-release) =~ CentOS ]]; then
        if ! package_exists python3-certbot-nginx; then
            yum install -y certbot python3-certbot-nginx
            # 1. Run `sudo certbot --nginx' to configure current domain.
            # 2. Test if can renew certbot successful. `sudo certbot renew --dry-run'
            # 3. Add following crontab, will date cert first day of month.
            #    0 0 1 * * /usr/bin/certbot renew
            # more detail, check https://certbot.eff.org/        fi
        fi

        if ! package_exists nginx; then
            # wget https://nginx.org/packages/centos/8/x86_64/RPMS/nginx-1.20.1-1.el8.ngx.x86_64.rpm
            # sudo rpm -ivh nginx-1.20.1-1.el8.ngx.x86_64.rpm
            # systemctl enable nginx

            cat <<'HEREDOC' > /etc/yum.repos.d/nginx.repo
    [nginx-stable]
    name=nginx stable repo
    baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
    gpgcheck=1
    enabled=1
    gpgkey=https://nginx.org/keys/nginx_signing.key
    module_hotfixes=true

    [nginx-mainline]
    name=nginx mainline repo
    baseurl=http://nginx.org/packages/mainline/centos/$releasever/$basearch/
    gpgcheck=1
    enabled=0
    gpgkey=https://nginx.org/keys/nginx_signing.key
    module_hotfixes=true
HEREDOC

            sudo yum-config-manager --enable nginx-stable
            sudo yum install -y nginx
        fi
    fi
}

function deploy_nginx_bri_support () {
    package libpcre3-dev zlib1g-dev libssl-dev

    nginx_version=$(sudo nginx -v 2>&1 |cut -d'/' -f2)
    wget https://nginx.org/download/nginx-${nginx_version}.tar.gz

    tar xvf nginx-${nginx_version}.tar.gz
    cd nginx-${nginx_version}
    git clone https://github.com/google/ngx_brotli.git
    cd ngx_brotli && git submodule update --init && cd -
    ./configure --with-compat --add-dynamic-module=./ngx_brotli
    make modules
    sudo cp objs/*.so /etc/nginx/modules/

    # Then, add following config into /etc/nginx/nginx.conf to load module.

    # load_module modules/ngx_http_brotli_filter_module.so;
    # load_module modules/ngx_http_brotli_static_module.so;
}

function deploy_tls () {
    set -u
    local domain_name=$1
    local reload_command=$2
    local stop_nginx=false

    domain_name_ip=$(ping "${domain_name}" -c 1 | sed '1{s/[^(]*(//;s/).*//;q}')

    if [[ "$domain_name_ip" != "$targetip" ]]; then
        echo "Your $domain_name ip is not same as $targetip, exit ..."
        exit 1
    fi

    package socat
    # install acme.sh script
    wget -O -  https://get.acme.sh | bash
    ~/.acme.sh/acme.sh  --upgrade  --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    if is_listen 80 && which nginx &>/dev/null; then
        stop_nginx=true
        reload_command="${reload_command}; systemctl restart nginx;"
    fi

    if ! [ -e ~/.acme.sh/${domain_name}_ecc/fullchain.cer ]; then
        [ "$stop_nginx" == true ] && systemctl stop nginx
        ~/.acme.sh/acme.sh --issue --standalone -d "${domain_name}" -k ec-256 --force
        [ "$stop_nginx" == true ] && systemctl start nginx
    fi

    mkdir -p /etc/ssl/$domain_name

    ~/.acme.sh/acme.sh --installcert --ecc --force \
                       -d "${domain_name}" \
                       --fullchainpath /etc/ssl/$domain_name/fullchain.pem \
                       --keypath /etc/ssl/$domain_name/privkey.pem \
                       --reloadcmd "$reload_command"

    if [[ $(stat -c%s /etc/ssl/$domain_name/fullchain.pem) -ge 5000 ]]; then
        echo "Certificate install to \`[0m[0;33m/etc/ssl/$domain_name/fullchain.pem[0m', \`[0m[0;33m/etc/ssl/$domain_name/privkey.pem[0m'"
    else
        echo 'Install certificate failed?'
        exit 1
    fi
}

# for use with asuswrt merlin only.
function add_service {
    [ -e /jffs/scripts/$1 ] || echo '#!/bin/sh' > /jffs/scripts/$1
    chmod +x /jffs/scripts/$1
    fgrep -qs -e "$2" /jffs/scripts/$1 || echo "$2" >> /jffs/scripts/$1
}


# # only support define a bash variable, bash array variable not supported.
# function export () {
#     if [ $# == 0 ]; then
#         echo 'Use export like this: export var=val'
#         return 1
#     fi

#     if [ $# -gt 1 ]; then
#         echo 'Only one variable be allowed.'
#         return 1
#     fi

#     local name=$(echo "$*" |cut -d'=' -f1)
#     local value=$(echo "$*" |cut -d'=' -f2-)
#     local escaped_value=$(echo "$value" |sed 's#\([\$"\`]\)#\\\1#g')

#     eval 'builtin export $name="$value"'
#     export_hooks="$export_hooks builtin export $name=\"$escaped_value\""
# }

function export () {
    eval 'builtin export $@'
    export_hooks="$export_hooks
 builtin export $@"
}

function export_function () {
    eval 'builtin export -f $*'
    new_function=$(type dockerinit |tail -n +2)
    export_hooks="$export_hooks
$new_function
builtin export -f $*"
}

# stolen from https://raw.githubusercontent.com/teddysun/across/master/bbr.sh
function kernel_version_greater_than () {
    local kernel_version=$(uname -r | cut -d- -f1)
    test "$(echo "$kernel_version $1" | tr " " "\n" | sort -rV | head -n 1)" == "$kernel_version"
}
