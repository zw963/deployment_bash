#!/bin/bash

function detect_target () {
    if [[ "$target" =~ [-_.[:alnum:]]+@.+ ]]; then
        target=${BASH_REMATCH[0]}
    elif [[ "$target" =~ [a-zA-Z0-9_.]+ ]]; then
        # 域名
        target=${BASH_REMATCH[0]}
    elif [[ "$target" == localhost ]]; then
        target=$target
    else
        echo "\`\$target' variable must be provided in your's scripts before $FUNCNAME."
        echo 'e.g. target=localhost or target=root@123.123.123.123'
        exit
    fi
}

function extract_remote_script {
    awk "/^[[:space:]]*$*/,EOF" |tail -n +2
}

function deploy_start {
    detect_target

    local preinstall="$(echo "$self" |extract_remote_script "export -f $FUNCNAME")
$export_hooks
export target=$target
export targetip=$(echo $target |cut -d'@' -f2)
sudo=$sudo
_modifier=$USER
echo '***********************************************************'
echo Remote deploy scripts is started !!
echo '***********************************************************'
set -ue
"
    local deploy_script="$preinstall$(cat $0 |extract_remote_script $FUNCNAME)"

    if [ -z "$SSH_CLIENT$SSH_TTY" ]; then
        set -u
        # 检测是否存在 bash.
        ssh $target bash --version
        if [ $? == 127 ]; then
            # 只有路由器这么老土的 linux 系统才没有 bash.
            echo 'remote host missing bash, try to install it...'
            ssh $target 'opkg install bash'
        fi
        ssh $target bash <<< "$deploy_script"
        exit 0
    fi
}

export -f deploy_start

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
        return
    fi

    __rsync "$@"

    if [ $? == 127 ]; then
        echo "[0m[33mrsync is not installed in remote host, fallback to use scp command.[0m"
        __use_scp=true
        __scp "$@"
    fi
}

function __rsync () {
    local local_file remote_file remote_dir
    local_file=$1
    remote_file=$2
    remote_dir=$(dirname $remote_file)

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

    $sudo command rsync -htpPvr -z -L --rsync-path="mkdir -p $remote_dir && rsync" "$local_file" $target:"$remote_file" "${@:3}"
}

function __scp () {
    local local_file remote_file remote_dir
    local_file=$1
    remote_file=$2
    remote_dir=$(dirname $remote_file)

    ssh $target mkdir -p $remote_dir
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

function daemon () {
    local name=$1
    local command=$2

    getent passwd $name || useradd $name -s /sbin/nologin

    cat <<HEREDOC > /etc/systemd/system/$name.service
     [Unit]
     Description=$name Service
     After=network.target

     [Service]
     Type=simple
     User=$name
     ExecStart=$command
     ExecReload=/bin/kill -USR1 \$MAINPID
     Restart=on-abort
     LimitNOFILE=51200
     LimitCORE=infinity
     LimitNPROC=51200

     [Install]
     WantedBy=multi-user.target
HEREDOC
    systemctl daemon-reload
    systemctl start $name
    systemctl enable $name
    systemctl status $name

    # 停止和关闭的命令如下:
    # systemctl stop shadowsocks
    # systemctl disable shadowsocks
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
        grep "^\\s*${regexp}\\s*" "$file"
    else
        set +e
        match_multiline "$content" "$(cat $file)"
    fi

    if ! [ $? == 0 ]; then
        # echo -e "\n#= Add by ${_modifier-$USER} =#" >> "$file"
        echo "$content" >> "$file"
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
        $sudo sed -i 1i"$content_escaped" "$file"
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

function match_multiline() {
    local regex content
    # 将 regexp 的换行符 换为一个不可见字符.
    # 注意: 这里 $1 已经是一个 regex
    regex=$(echo "$1" |tr '\n' '\a')

    # 文本内容也将 换行符 换为一个不可见字符.
    content=$(echo "$2"|tr '\n' '\a')

    # 多行匹配, 选择文本匹配, 而不是正则.
    echo "$content" |fgrep "$regex"
}

function replace () {
    local regexp replace file content
    regexp=$1
    replace="$(echo "$2" |replace_escape)"
    file=$3

    if content=$(grep -o -e "$regexp" "$file"); then
        $sudo sed -i -e "s/$regexp/$replace/" "$file"
        echo "\`[0m[33m$content[0m' is replaced with \`[0m[33m$replace[0m' for $file"
    fi
}

function replace_regex () {
    local regexp=$1
    local replace=$2
    local config_file=$3

    replace "$regexp" "$replace" "$config_file"
}

function replace_string () {
    local string=$1
    local regexp="$(echo "$string" |regexp_escape)"
    local replace=$2
    local config_file=$3

    replace "$regexp" "$replace" "$config_file"

    # only matched string exist, replace with new string.
    # if matched_line=$(grep -s "$regexp" $config_file|tail -n1) && test -n "$matched_line"; then
    #     local matched_line_regexp=$(echo "$matched_line" |regexp_escape)
    #     local replaced_line=$(echo "$matched_line"|sed "s/$regexp/$replace_string/")

    #     # sed -i -e "s/^${matched_line_regexp}$/\n#= &\n#= Above config-default value is replaced by following config value. $(date '+%Y-%m-%d %H:%M:%S') by ${_modifier-$USER}\n$replaced_line/" $config_file
    #     sed -i -e "s/^${matched_line_regexp}$/$replaced_line/" $config_file

    #     echo "\`$old_string' is replaced in $config_file."
    # fi
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
    local url=$1
    local file=$(basename $url)
    command wget --no-check-certificate -c $url -O $file
}

function curl () {
    command curl -sS -L "$@"
}

function download_and_extract () {
    local ext=$( basename "$1" |rev|cut -d'.' -f1|rev)
    local name=$(basename "$1" |rev|cut -d'.' -f2-|rev |sed 's#.tar$##')
    local dest="${2-$name}"
    mkdir -p $dest
    case $ext in
        gz|tgz)
            curl "$1" |tar -zxvf - -C "$dest" --strip-components=1
            ;;
        bz2)
            curl "$1" |tar -jxvf - -C "$dest" --strip-components=1
            ;;
        xz|txz)
            curl "$1" |tar -Jxvf - -C "$dest" --strip-components=1
            ;;
        lzma)
            curl "$1" |tar --lzma -xvf - -C "$dest" --strip-components=1
            ;;
        zip)
            local fullname=$(basename $1)

            temp_dir=$(mktemp -d) &&
                curl -o $temp_dir/$fullname "$1" &&
                unzip $temp_dir/"$fullname" -d "$temp_dir" &&
                rm "$temp_dir/$fullname" &&
                shopt -s dotglob &&
                local f=("$temp_dir"/*) &&
                if (( ${#f[@]} == 1 )) && [[ -d "${f[0]}" ]] ; then
                    mv "$temp_dir"/*/* "$dest"
                else
                    mv "$temp_dir"/* "$dest"
                fi && rmdir "$temp_dir"/* "$temp_dir"
    esac

}

function diff () {
    command diff -q "$@" >/dev/null
}

function sshkeygen () {
    ssh-keygen -t rsa -f ~/.ssh/id_rsa -N ''
}

# function rc.local () {
#     local conf=/etc/rc.local

#     fgrep -qs "$*" $conf || echo "$*" >> $conf
#     chmod +x $conf
#     # $*
# }

function expose_port () {
    for port in "$@"; do
        if grep -qs 'Ubuntu\|Mint|Debian' /etc/issue; then
            # systemctl status ufw
            # ufw 中, 允许端口 1098, ufw allow 1098
            # rc.local "iptables -I INPUT -p tcp --dport $port -j ACCEPT"
            # rc.local "iptables -I INPUT -p udp --dport $port -j ACCEPT"
            echo 'no need install iptables'
        elif grep -qs CentOS /etc/redhat-release; then
            firewall-cmd --zone=public --add-port=$port/tcp --permanent
            firewall-cmd --zone=public --add-port=$port/udp --permanent
            firewall-cmd --reload   # 这个只在 --permanent 参数存在时, 才需要
            # firewall-cmd --zone=public --list-ports
        elif grep -qs openSUSE /etc/issue; then
            yast firewall services add tcpport=$port zone=EXT
        fi
    done
}

function package () {
    local install installed
    # for Ubuntu build-essential
    # for centos yum groupinstall "Development Tools"
    local compile_tools='gcc autoconf automake make libtool bzip2 unzip patch wget curl perl'
    local basic_tools='mlocate git tree'

    if grep -qs 'Ubuntu\|Mint|Debian' /etc/issue; then
        $sudo apt-get update
        install="$sudo apt-get install -y --no-install-recommends"
    elif grep -qs CentOS /etc/redhat-release; then
        # if Want get centos version, use `rpm -q centos-release'.
        install="$sudo yum install -y"
    elif grep -qs openSUSE /etc/issue; then
        install="$sudo zypper -n in --no-recommends"
    fi

    installed=
    if grep -qs 'Ubuntu\|Mint|Debian' /etc/issue; then
        basic_tools="$basic_tools"
        for i in "$@"; do
            case "$i" in
                zlib-devel)
                    installed="$installed zlib1g-dev"
                    ;;
                openssl-devel)
                    installed="$installed libssl-dev"
                    ;;
                libffi-devel)
                    installed="$installed libffi-dev"
                    ;;
                readline-devel)
                    installed="$installed libreadline-dev"
                    ;;
                libyaml-devel)
                    installed="$installed libyaml-dev"
                    ;;
                ncurses-devel)
                    installed="$installed libncurses5-dev"
                    ;;
                gdbm-devel)
                    installed="$installed libgdbm-dev"
                    ;;
                sqlite-devel)
                    installed="$installed libsqlite3-dev"
                    ;;
                gmp-devel)
                    installed="$installed libgmp-dev"
                    ;;
                pcre-devel)
                    installed="$installed libpcre3-dev"
                    ;;
                libsodium-devel)
                    installed="$installed libsodium-dev"
                    ;;
                udns-devel)
                    installed="$installed libudns-dev"
                    ;;
                libev-devel)
                    installed="$installed libev-dev"
                    ;;
                mbedtls-devel)
                    installed="$installed libmbedtls-dev"
                    ;;
                compile-tools)
                    installed="$installed $compile_tools g++ xz-utils pkg-config"
                    ;;
                *)
                    installed="$installed $i"
            esac
        done
    elif grep -qs CentOS /etc/redhat-release; then
        basic_tools="$basic_tools yum-cron yum-utils epel-release"
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
        $install $i
    done

    for i in $installed; do
        $install $i
    done
}

# for use with asuswrt merlin only.
function add_service {
    [ -e /jffs/scripts/$1 ] || echo '#!/bin/sh' > /jffs/scripts/$1
    chmod +x /jffs/scripts/$1
    fgrep -qs -e "$2" /jffs/scripts/$1 || echo "$2" >> /jffs/scripts/$1
}


# only support define a bash variable, bash array variable not supported.
function __export () {
    local name=$(echo "$*" |cut -d'=' -f1)
    local value=$(echo "$*" |cut -d'=' -f2-)
    local escaped_value=$(echo "$value" |sed 's#\([\$"`]\)#\\\1#g')

    eval 'builtin export $name="$value"'
    export_hooks="$export_hooks builtin export $name=\"$escaped_value\""
}

alias export=__export
