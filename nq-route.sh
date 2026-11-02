#!/usr/bin/env bash
# =====================================================================
#  nq-route.sh — NodeQuality 回程路由测试 · 精简独立版
#
#  仅保留 NodeQuality(LloydAsp/NodeQuality) 与 NetQuality(xykt) 中
#  回程路由追踪(Backroute Trace)的部分:
#    · 三网回程: 上海/北京/广东 × 电信/联通/移动, TCP 80 端口
#    · 路由类型判定: 163 / CN2 GT / CN2 GIA / CTG GIA / 4837 /
#      9929 / 10099(CUII) / CMI / CMIN2 / CERNET / CSTNET
#    · 途径地理路径、骨干 AS 路径、逐跳明细(含去重合并)
#
#  去掉了: BenchOS 临时系统下载与 mount/chroot、硬件/IP/网速测试、
#  结果上传(本脚本不向任何服务器上传数据)。
#
#  用法:
#    bash nq-route.sh                # IPv4 + IPv6(可用时), 三省三网
#    bash nq-route.sh -4             # 仅 IPv4
#    bash nq-route.sh -6             # 仅 IPv6
#    bash nq-route.sh -p gd          # 仅广东三网
#    bash nq-route.sh -p gd,zj       # 多省
#    bash nq-route.sh -t 6           # 限制并发线程
#    bash nq-route.sh -k             # nexttrace 保留到 /usr/local/bin
#
#  依赖: bash 4.3+ / curl / timeout; 建议 root(nexttrace 需要原始套接字)
# =====================================================================

nt_version="v1.3.7"
nt_base="https://github.com/nxtrace/NTrace-core/releases/download/${nt_version}"
script_version="1.1.0"

# ---------- 字体/颜色 ----------
Font_B="\033[1m"
Font_Red="\033[31m"
Font_Green="\033[32m"
Font_Yellow="\033[33m"
Font_Purple="\033[35m"
Font_Cyan="\033[36m"
Font_White="\033[37m"
Back_Blue="\033[44m"
Back_Cyan="\033[46m"
Back_Green="\033[42m"
Back_Purple="\033[45m"
Back_White="\033[47m"
Font_Suffix="\033[0m"

# ---------- 省份表 (来自 xykt/NetQuality ref/province.json, province<70) ----------
# 键: 域名小写代码; 值: "显示名|简称"
declare -A PROV=(
    [bj]="北京|京"    [tj]="天津|津"    [he]="河北|冀"    [sx]="山西|晋"
    [nm]="内蒙古|蒙"  [ln]="辽宁|辽"    [jl]="吉林|吉"    [hl]="黑龙江|黑"
    [sh]="上海|沪"    [js]="江苏|苏"    [zj]="浙江|浙"    [ah]="安徽|皖"
    [fj]="福建|闽"    [jx]="江西|赣"    [sd]="山东|鲁"    [ha]="河南|豫"
    [hb]="湖北|鄂"    [hn]="湖南|湘"    [gd]="广东|粤"    [gx]="广西|桂"
    [hi]="海南|琼"    [cq]="重庆|渝"    [sc]="四川|川"    [gz]="贵州|贵"
    [yn]="云南|云"    [xz]="西藏|藏"    [sn]="陕西|陕"    [gs]="甘肃|甘"
    [qh]="青海|青"    [nx]="宁夏|宁"    [xj]="新疆|新"
)

# ---------- 常见国际/港澳骨干 ASN 映射 (来自 xykt/NetQuality ref/AS_Mapping.txt) ----------
declare -A AS_MAPPING=(
    [AS174]=Cogent   [AS701]=Verizon   [AS702]=Verizon   [AS1239]=Sprint
    [AS1273]=Vodafone [AS1299]=Arelion [AS2497]=IIJ     [AS2516]=KDDI
    [AS2914]=NTT     [AS3209]=Vodafone [AS3257]=GTT     [AS3258]=xTom
    [AS3301]=Telia   [AS3320]=DTAG    [AS3356]=Lumen    [AS3462]=Hinet
    [AS3491]=PCCW    [AS3786]=LG      [AS4609]=CTM      [AS4637]=Telstra
    [AS4657]=StarHub [AS4766]=KT      [AS4788]=TMNet    [AS5511]=Orange
    [AS6233]=xTom    [AS6453]=TATA    [AS6461]=Zayo     [AS6762]=Sparkle
    [AS6830]=Liberty [AS6939]=HE      [AS7018]="AT&T"   [AS7473]=SingTel
    [AS7922]=Comcast [AS8075]=MS      [AS8888]=xTom     [AS9002]=RETN
    [AS9269]=HKBN    [AS9304]=HGC     [AS9505]=CHT      [AS17676]=Softbank
    [AS12389]=RT_RU  [AS12876]=Scaleway [AS12956]=Telxius [AS13335]=CF
    [AS15169]=Google [AS15802]=DU     [AS16276]=OVH     [AS16509]=Amazon
    [AS20473]=Vultr  [AS20485]=TTK_RU [AS23961]=Misaka  [AS24940]=Hetzner
    [AS25820]=IT7    [AS30844]=Liquid [AS31898]=Oracle  [AS45102]=Alibaba
    [AS4760]=HKT     [AS4775]=Globe   [AS4809]=CN2      [AS58453]=CMI
    [AS9808]=CMNET   [AS10099]=CUII   [AS4538]=CERNET
)

# ---------- 状态变量 ----------
declare -A rmresu rmallasn rmallgeo rmmaxhop rmcnhop rmcn rmww rmcode
declare -a TARGET_PROVS=()
declare rmgia=0
rmtestnum=0
opt_ipv=""          # "" = 自动双栈, -4 / -6
opt_prov=""         # 空 = 默认 sh,bj,gd
opt_threads=0       # 0 = 按内存自动
opt_keep=0
opt_selftest=0
nt_bin=""
tmp_dir=""

# =====================================================================
#  辅助函数 (均移植自 NetQuality)
# =====================================================================
mask_ip(){
    local ip=$1
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip" | awk -F. '{print $1"."$2".*.*"}'
    elif [[ $ip =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; then
        echo "$ip" | awk -F: '{
            keep = 8 - 5
            for(i=1; i<=NF; i++) {
                if(i <= keep) { printf "%s", $i } else { printf "*" }
                if(i < 8) printf ":"
            }
            if(NF < 8) {
                for(i=NF+1; i<=8; i++) {
                    if(i <= keep) { printf "0" } else { printf "*" }
                    if(i < 8) printf ":"
                }
            }
        }'
    else
        return 1
    fi
}

extract_region(){
    local input=$1
    local part
    IFS=' ' read -ra parts <<<"$input"
    for part in "${parts[@]}"; do
        if [[ -z $part || $part =~ ^[[:punct:]]+$ || $part == *"."* || $part == *"RFC"* || $part == *"rfc"* || $part == *"Private"* || $part == *"Local"* || $part == *"DOD"* || $part == *"Anycast"* || $part == *"ASAPI"* || $part == *"网络故障"* ]]; then
            continue
        fi
        local pattern suffix
        for pattern in "*" "中国" "电信" "联通" "移动"; do
            [[ $part == "$pattern" ]] && continue 2
        done
        for suffix in "省" "市" "县" "维吾尔自治区" "回族自治区" "壮族自治区" "自治区" "特别行政区"; do
            if [[ $part == *"$suffix" ]]; then
                part="${part%"$suffix"}"
                break
            fi
        done
        echo "$part"
        return
    done
    echo ""
}

colorize_latency(){
    local latency_ms=$1
    local total_length=${2:-2}
    if [[ ! $latency_ms =~ ^[0-9]+(\.[0-9]+)?ms$ ]]; then
        return 0
    fi
    local value=${latency_ms%ms}
    local level
    level=$(awk -v v="$value" 'BEGIN{print (v<=150)?"g":(v<=240)?"y":"r"}')
    local colored
    case $level in
        g) colored="$Font_Green$latency_ms" ;;
        y) colored="$Font_Yellow$latency_ms" ;;
        *) colored="$Font_Red$latency_ms" ;;
    esac
    local pad=$((total_length - ${#latency_ms}))
    ((pad > 0)) && colored="$(printf "%${pad}s" "")$colored"
    echo -ne "$colored$Font_Suffix"
}

# =====================================================================
#  回程追踪 (移植自 NetQuality nexttrace_route, awk 解析保持一致)
# =====================================================================
nexttrace_route(){
    # $1 目标域名 $2 序号 $3 地址族(4/6)
    local domain="$1" rnum="$2" ipv="$3"
    local output retry_count=0
    local max_retries=10 retry_delay=5
    while ((retry_count < max_retries)); do
        output=$(timeout -s SIGKILL 50 "$nt_bin" -p 80 -q 8 -"$ipv" --tcp --psize 1400 "$domain" 2>/dev/null)
        [[ $output != *"please try again later"* && $output == *"traceroute to"* ]] && break
        retry_count=$((retry_count + 1))
        ((retry_count < max_retries)) && sleep "$retry_delay"
    done
    output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    echo "$output" | awk -v rnum="$rnum" '
    {
        if ($1 ~ /^[0-9]+$/) {
            hop = $1
            ip = $2
            if (ip != "*") {
                as = ""
                bracket = ""
                desc = ""
                ms = ""
                for (i = 3; i <= NF; i++) {
                    if ($i ~ /^AS[0-9]+/) {
                        as = $i
                    } else if ($i ~ /^\[.*\]$/) {
                        bracket = $i
                    } else {
                        desc = desc " " $i
                    }
                }
                sub(/^ /, "", desc)
                getline next_line
                if (next_line ~ /[0-9]+\.[0-9]+ ms/) {
                    match(next_line, /[0-9]+\.[0-9]+ ms/)
                    ms = substr(next_line, RSTART, RLENGTH)
                    gsub(/ /, "", ms)
                }
                printf "|%s|%s|%s|%s|%s|%s|%s|\n", rnum, hop, ms, ip, as, bracket, desc
            }
        }
    }'
}

# =====================================================================
#  结果聚合与路由类型判定 (移植自 NetQuality get_route_mode)
# =====================================================================
aggregate_results(){
    local n=$1 res_dir=$2
    local line i1 i2
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        IFS='|' read -ra fields <<<"$line"
        i1=$(printf "%02d" "${fields[1]}")
        i2=$(printf "%02d" "${fields[2]}")
        rmresu["$i1${i2}1"]="${fields[3]}"
        rmresu["$i1${i2}2"]=$(mask_ip "${fields[4]}")
        rmresu["$i1${i2}3"]="${fields[5]}"
        rmresu["$i1${i2}4"]="${fields[6]}"
        rmresu["$i1${i2}5"]="${fields[7]}"
        rmresu["$i1${i2}6"]=$(extract_region "${rmresu[$i1${i2}5]}")
        # CN2 / CTGNet 骨干识别
        [[ ${rmresu["$i1${i2}2"]} == 59.43.* ]] && rmresu["$i1${i2}3"]="AS4809"
        [[ ${rmresu["$i1${i2}5"]} == *CTGNet* ]] && rmresu["$i1${i2}3"]="AS23764"
        # 首个中国大陆入网点
        if [[ -z ${rmcnhop["$i1"]} ]] && [[ ${rmresu["$i1${i2}5"]} == *中国* ]] && [[ ${rmresu["$i1${i2}5"]} != *香港* ]] && [[ ${rmresu["$i1${i2}5"]} != *澳门* ]] && [[ ${rmresu["$i1${i2}5"]} != *台湾* ]]; then
            rmcnhop["$i1"]="$i2"
        fi
        # 地理路径
        if [[ -n ${rmresu[$i1${i2}6]} ]]; then
            if [[ ${rmallgeo[$i1]} == *"${rmresu[$i1${i2}6]}"* ]]; then
                rmallgeo[$i1]="${rmallgeo[$i1]%${rmresu[$i1${i2}6]}*}${rmresu[$i1${i2}6]}"
            else
                [[ -n ${rmallgeo[$i1]} ]] && rmallgeo[$i1]="${rmallgeo[$i1]} -> "
                rmallgeo[$i1]="${rmallgeo[$i1]}${rmresu[$i1${i2}6]}"
            fi
        fi
        # AS 路径
        if [[ -n ${rmresu["$i1${i2}3"]} && ${rmallasn[$i1]} != *"${rmresu[$i1${i2}3]}"* ]]; then
            [[ -n ${rmallasn[$i1]} ]] && rmallasn[$i1]="${rmallasn[$i1]} -> "
            rmallasn[$i1]="${rmallasn[$i1]}${rmresu[$i1${i2}3]}"
        fi
        # 最大跳数
        local vara=${i2#0}
        local varb="${rmmaxhop[$i1]:-0}"
        varb=${varb#0}
        ((vara > varb)) && rmmaxhop["$i1"]="$i2"
    done < <(cat "$res_dir"/r.*.txt 2>/dev/null)

    # 路由类型判定
    local ii thop hop vara varb
    for ((i = 1; i <= n; i++)); do
        ii=$(printf "%02d" "$i")
        rmcn[$ii]="Unknown"
        rmww[$ii]="Unknown"
        [[ ${rmcnhop[$ii]} == 0 || ${rmcnhop[$ii]} == ${rmmaxhop[$ii]} ]] && rmcn[$ii]="Hidden"
        vara="${rmcnhop[$ii]:-0}"
        vara=${vara#0}
        # AS17676(软银移动) 特判: 入网点取下一跳
        [[ ${rmresu[$ii${rmcnhop[$ii]}3]} == "AS17676" ]] && rmcnhop[$ii]=$(printf "%02d" "$((vara + 1))")
        case "${rmresu[$ii${rmcnhop[$ii]}3]}" in
            "AS4134")
                rmcn[$ii]="163"
                ;;
            "AS4837")
                rmcn[$ii]="4837"
                vara="${rmcnhop[$ii]:-0}"
                vara=${vara#0}
                if ((vara > 1)); then
                    varb=$(printf "%02d" "$((vara - 1))")
                    [[ ${rmresu[$ii${varb}3]} == "AS10099" ]] && rmcn[$ii]="10099"
                fi
                ;;
            "AS58453")
                rmcn[$ii]="CMI"
                ;;
            "AS58807")
                rmcn[$ii]="CMIN2"
                ;;
            "AS9808")
                rmcn[$ii]="CMI"
                [[ ${rmallasn[$ii]} == *AS58807* ]] && rmcn[$ii]="CMIN2"
                ;;
            "AS9929")
                rmcn[$ii]="9929"
                ;;
            "AS10099")
                rmcn[$ii]="10099"
                [[ ${rmallasn[$ii]} == *AS9929* ]] && rmcn[$ii]="9929"
                ;;
            "AS4809")
                rmcn[$ii]="CN2GIA"
                if [[ ${rmallasn[$ii]} == *AS23764* ]]; then
                    rmcn[$ii]="CTGGIA"
                fi
                if [[ $rmgia -ne 1 ]]; then
                    vara="${rmcnhop[$ii]:-0}"
                    varb="${rmmaxhop[$ii]:-0}"
                    vara=${vara#0}
                    varb=${varb#0}
                    for ((thop = vara; thop <= varb; thop++)); do
                        hop=$(printf "%02d" "$thop")
                        [[ ${rmresu[$ii${hop}3]} == "AS4809" || ${rmresu[$ii${hop}3]} == "AS23764" ]] && continue
                        if [[ ${rmresu[$ii${hop}2]} == 202.97* ]]; then
                            rmcn[$ii]="CN2GT"
                        fi
                        break
                    done
                fi
                ;;
            "AS23764")
                rmcn[$ii]="CTGGIA"
                if [[ $rmgia -ne 1 ]]; then
                    vara="${rmcnhop[$ii]:-0}"
                    varb="${rmmaxhop[$ii]:-0}"
                    vara=${vara#0}
                    varb=${varb#0}
                    for ((thop = vara; thop <= varb; thop++)); do
                        hop=$(printf "%02d" "$thop")
                        [[ ${rmresu[$ii${hop}3]} == "AS4809" || ${rmresu[$ii${hop}3]} == "AS23764" ]] && continue
                        if [[ ${rmresu[$ii${hop}2]} == 202.97* ]]; then
                            rmcn[$ii]="CN2GT"
                        fi
                        break
                    done
                fi
                ;;
            "AS4538")
                rmcn[$ii]="CERNET"
                ;;
            "AS7497")
                rmcn[$ii]="CSTNET"
                ;;
            *)
                rmcn[$ii]="NoData"
                if [[ ${rmallasn[$ii]} == *AS58807* ]]; then
                    rmcn[$ii]="CMIN2"
                elif [[ ${rmallasn[$ii]} == *AS9929* ]]; then
                    rmcn[$ii]="9929"
                elif [[ ${rmallasn[$ii]} == *AS10099* ]]; then
                    rmcn[$ii]="10099"
                elif [[ ${rmallasn[$ii]} == *AS4809* ]]; then
                    rmcn[$ii]="CN2"
                elif [[ ${rmallasn[$ii]} == *AS9808* ]]; then
                    rmcn[$ii]="CMI"
                elif [[ ${rmallasn[$ii]} == *AS4134* ]]; then
                    rmcn[$ii]="163"
                elif [[ ${rmallasn[$ii]} == *AS4837* ]]; then
                    rmcn[$ii]="4837"
                fi
                ;;
        esac
        [[ ${rmcn[$ii]} == *GIA ]] && rmgia=1
        # 回溯境外段: 从入网点向前找第一个非三网骨干 ASN
        vara="${rmcnhop[$ii]:-0}"
        vara=${vara#0}
        for ((thop = vara - 1; thop > 0; thop--)); do
            hop=$(printf "%02d" "$thop")
            if [[ -n ${rmresu[$ii${hop}3]} && ${rmresu[$ii${hop}3]} != "AS58453" && ${rmresu[$ii${hop}3]} != "AS58807" && ${rmresu[$ii${hop}3]} != "AS4837" && ${rmresu[$ii${hop}3]} != "AS10099" && ${rmresu[$ii${hop}3]} != "AS9929" && ${rmresu[$ii${hop}3]} != "AS4134" && ${rmresu[$ii${hop}3]} != "AS4809" && ${rmresu[$ii${hop}3]} != "AS4808" && ${rmresu[$ii${hop}3]} != "AS23764" && ${rmresu[$ii${hop}3]} != "AS4538" && ${rmresu[$ii${hop}3]} != "AS7497" ]]; then
                rmww[$ii]="${rmresu[$ii${hop}3]}"
                break
            fi
        done
        if [[ -n ${rmww[$ii]} && ${rmww[$ii]} != "Unknown" ]]; then
            [[ -n ${AS_MAPPING[${rmww[$ii]}]} ]] && rmww[$ii]="${AS_MAPPING[${rmww[$ii]}]}"
        fi
    done
}

# =====================================================================
#  结果输出 (移植自 NetQuality show_route 的 -R 分支)
# =====================================================================
display_results(){
    local ipver=$1 n=$2
    local i ii j jj k kk varb mergeroute mergejump compA compB tmpdelay tmppv tmpfont tmpback
    for ((i = 1; i <= n; i++)); do
        ii=$(printf "%02d" "$i")
        case $((i % 3)) in
            1) tmppv="电信"; tmpfont="$Font_Cyan";   tmpback="$Back_Cyan" ;;
            2) tmppv="联通"; tmpfont="$Font_Green";  tmpback="$Back_Green" ;;
            0) tmppv="移动"; tmpfont="$Font_Purple"; tmpback="$Back_Purple" ;;
        esac
        echo -ne "$tmpback$Font_White$Font_B  ${rmcode[$i]} $tmppv  $Font_Suffix$Back_White$tmpfont$Font_B  ${rmww[$ii]} -> ${rmcn[$ii]}  $Font_Suffix\n"
        echo -ne "$Back_Blue$Font_White地理路径：${rmallgeo[$ii]}    自治系统路径：${rmallasn[$ii]} $Font_Suffix\n"
        varb="${rmmaxhop[$ii]:-0}"
        varb=${varb#0}
        mergejump="   "
        for ((j = 1; j <= varb; j++)); do
            jj=$(printf "%02d" "$j")
            mergeroute=0
            mergejump="   "
            if [[ -n ${rmresu[$ii${jj}2]} ]]; then
                compA="${rmresu[$ii${jj}5]#"${rmresu[$ii${jj}5]%%[![:space:]\*]*}"}"
                compA=$(awk '{print $1 " " $2}' <<<"$compA")
                for ((k = j + 1; k < varb; k++)); do
                    kk=$(printf "%02d" "$k")
                    compB="${rmresu[$ii${kk}5]#"${rmresu[$ii${kk}5]%%[![:space:]\*]*}"}"
                    compB=$(awk '{print $1 " " $2}' <<<"$compB")
                    if [[ -n ${rmresu[$ii${kk}2]} && ${rmresu[$ii${jj}3]} == "${rmresu[$ii${kk}3]}" && ${rmresu[$ii${jj}4]} == "${rmresu[$ii${kk}4]}" ]] && [[ $compA == *"$compB"* || $compB == *"$compA"* ]]; then
                        mergejump="-$(printf '%-2s' "$k")"
                        continue
                    fi
                    [[ -n ${rmresu[$ii${kk}2]} ]] && break
                done
                if ((j != varb)); then
                    for ((k = j - 1; k > 0; k--)); do
                        kk=$(printf "%02d" "$k")
                        compB="${rmresu[$ii${kk}5]#"${rmresu[$ii${kk}5]%%[![:space:]\*]*}"}"
                        compB=$(awk '{print $1 " " $2}' <<<"$compB")
                        if [[ -n ${rmresu[$ii${kk}2]} && ${rmresu[$ii${jj}3]} == "${rmresu[$ii${kk}3]}" && ${rmresu[$ii${jj}4]} == "${rmresu[$ii${kk}4]}" ]] && [[ $compA == *"$compB"* || $compB == *"$compA"* ]]; then
                            continue 2
                        fi
                    done
                fi
                tmpdelay=$(colorize_latency "${rmresu[$ii${jj}1]}" 9)
                if [[ $ipver == 4 ]]; then
                    echo -ne "$Font_B$(printf '%2s' "$j")$mergejump$Font_Suffix $tmpdelay  $(printf '%-13s' "${rmresu[$ii${jj}2]}")$Font_B$(printf '%-10s' "${rmresu[$ii${jj}3]}")$(printf '%-18s' "${rmresu[$ii${jj}4]}")$Font_Suffix${rmresu[$ii${jj}5]}\n"
                else
                    echo -ne "$Font_B$(printf '%2s' "$j")$mergejump$Font_Suffix $tmpdelay  $(printf '%-27s' "${rmresu[$ii${jj}2]}")$Font_B$(printf '%-10s' "${rmresu[$ii${jj}3]}")$Font_Suffix${rmresu[$ii${jj}5]}\n"
                fi
            fi
        done
        echo -ne "\n"
    done
}

# =====================================================================
#  环境准备
# =====================================================================
check_env(){
    # bash 版本
    if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
        echo -e "${Font_Red}错误: 需要 bash 4.3+ (当前 ${BASH_VERSION})${Font_Suffix}" >&2
        exit 1
    fi
    # 平台
    if [[ $(uname -s) != "Linux" ]]; then
        echo -e "${Font_Red}错误: 本脚本仅支持 Linux (当前 $(uname -s))${Font_Suffix}" >&2
        exit 1
    fi
    # 依赖
    local dep
    for dep in curl timeout awk sed; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo -e "${Font_Red}错误: 缺少依赖 $dep${Font_Suffix}" >&2
            exit 1
        fi
    done
    # root 提示
    if ((EUID != 0)); then
        echo -e "${Font_Yellow}提示: 建议 root 运行, 非 root 时 nexttrace 可能无法发送原始报文${Font_Suffix}" >&2
    fi
    export HOME="${HOME:-/root}"
}

install_nexttrace(){
    # 已安装且可用则复用
    if command -v nexttrace >/dev/null 2>&1; then
        nt_bin="$(command -v nexttrace)"
        return 0
    fi
    local arch
    case $(uname -m) in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l)         arch="armv7" ;;
        i386|i686)      arch="386" ;;
        *)
            echo -e "${Font_Red}错误: 不支持的架构 $(uname -m)${Font_Suffix}" >&2
            exit 1
            ;;
    esac
    local url="$nt_base/nexttrace_linux_$arch"
    echo -e "${Font_Cyan}下载 nexttrace ${nt_version} (${arch})...${Font_Suffix}" >&2
    if ! curl -L#o "$tmp_dir/nexttrace" "$url" 2>&1; then
        echo -e "\n${Font_Red}错误: nexttrace 下载失败, 请检查网络或 GitHub 连通性${Font_Suffix}" >&2
        exit 1
    fi
    chmod +x "$tmp_dir/nexttrace"
    nt_bin="$tmp_dir/nexttrace"
    if ! "$nt_bin" --version >/dev/null 2>&1; then
        echo -e "${Font_Red}错误: nexttrace 无法运行${Font_Suffix}" >&2
        exit 1
    fi
    if ((opt_keep)) && ((EUID == 0)); then
        cp -f "$nt_bin" /usr/local/bin/nexttrace 2>/dev/null \
            && echo -e "${Font_Green}nexttrace 已保留至 /usr/local/bin/nexttrace${Font_Suffix}" >&2
    fi
}

cleanup(){
    trap '' INT TERM EXIT
    jobs -pr 2>/dev/null | xargs -r kill 2>/dev/null
    [[ -n $tmp_dir && -d $tmp_dir ]] && rm -rf "$tmp_dir"
    exit 0
}

usage(){
    cat <<'EOF'
nq-route.sh — NodeQuality 回程路由测试(精简独立版)

用法: bash nq-route.sh [选项]

选项:
  -4          仅测试 IPv4 回程
  -6          仅测试 IPv6 回程
  -a          双栈(默认, IPv6 不可用时自动跳过)
  -p <省份>   指定省份(默认 上海,北京,广东), 可逗号分隔
              支持: gd / 粤 / 广东 / 广东省 等写法
  -t <数字>   并发线程数(默认按可用内存自动, 上限 18)
  -k          将 nexttrace 保留到 /usr/local/bin (免下次下载)
  -h          帮助

示例:
  bash nq-route.sh -4
  bash nq-route.sh -p gd -t 6
EOF
    exit 0
}

# =====================================================================
#  主流程
# =====================================================================
get_opts(){
    while (($# > 0)); do
        case $1 in
            -4) opt_ipv="-4" ;;
            -6) opt_ipv="-6" ;;
            -a) opt_ipv="" ;;
            -p)
                shift
                [[ -z ${1:-} ]] && { echo "参数错误: -p 需要省份" >&2; exit 1; }
                opt_prov="$1"
                ;;
            -t)
                shift
                [[ -z ${1:-} ]] && { echo "参数错误: -t 需要数字" >&2; exit 1; }
                opt_threads="$1"
                ;;
            -k) opt_keep=1 ;;
            --selftest) opt_selftest=1 ;;
            -h|--help) usage ;;
            *) echo "不支持的参数: $1 (使用 -h 查看帮助)" >&2; exit 1 ;;
        esac
        shift
    done
}

match_province(){
    # 将用户输入归一化为省份代码; 匹配 代码/简称/名称
    local input=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/省//g; s/市//g; s/县//g; s/维吾尔//g; s/回族//g; s/壮族//g; s/自治区//g; s/特别行政区//g')
    local code
    for code in "${!PROV[@]}"; do
        local name=$(echo "${PROV[$code]%%|*}" | sed 's/省//g; s/市//g; s/自治区//g')
        local short="${PROV[$code]##*|}"
        if [[ $input == "$code" || $input == "$short" || $input == "$name" ]]; then
            echo "$code"
            return 0
        fi
    done
    return 1
}

build_targets(){
    # 直接写入全局 TARGET_PROVS / rmcode / rmtestnum
    # 注意: 本函数不能在 $( ) 命令替换中调用, 否则子 shell 中全局赋值丢失
    local input code m
    TARGET_PROVS=()
    if [[ -n $opt_prov ]]; then
        IFS=',' read -ra input <<<"$opt_prov"
        for code in "${input[@]}"; do
            code="${code#"${code%%[![:space:]]*}"}"
            code="${code%"${code##*[![:space:]]}"}"
            m=$(match_province "$code") || { echo -e "${Font_Red}错误: 无法识别省份 '$code'${Font_Suffix}" >&2; exit 1; }
            TARGET_PROVS+=("$m")
        done
    else
        TARGET_PROVS=(bj sh gd)
    fi
    # 每省三个目标: 电信(ct) 联通(cu) 移动(cm), 与原版顺序一致
    local n=0 p
    for p in "${TARGET_PROVS[@]}"; do
        rmcode[$((++n))]="${PROV[$p]%%|*}"
        rmcode[$((++n))]="${PROV[$p]%%|*}"
        rmcode[$((++n))]="${PROV[$p]%%|*}"
    done
    rmtestnum=$((3 * ${#TARGET_PROVS[@]}))
}

check_family(){
    # 检测地址族可用性: 用首个目标域名做 curl 连通性探测
    local ipv=$1 prov=$2
    local domain="${prov}-ct-v${ipv#-}.ip.zstaticcdn.com"
    curl "-${ipv#-}" -m 8 -s -o /dev/null "http://$domain"
}

run_family(){
    # $1 = 地址族(4/6), 其余参数 = 省份代码数组
    local ipver=$1
    shift
    local provs=("$@") res_dir
    local prov
    res_dir="$tmp_dir/v4"
    [[ $ipver == 6 ]] && res_dir="$tmp_dir/v6"
    mkdir -p "$res_dir"

    # 自愈: 目标数与省份显示名由本函数入参直接重算, 不依赖外部全局状态
    rmtestnum=$((3 * ${#provs[@]}))
    local idx=0
    for prov in "${provs[@]}"; do
        rmcode[$((++idx))]="${PROV[$prov]%%|*}"
        rmcode[$((++idx))]="${PROV[$prov]%%|*}"
        rmcode[$((++idx))]="${PROV[$prov]%%|*}"
    done

    # 并发控制: 按可用内存估算(每个 nexttrace 约 28MB), 上限 18
    local max_threads=$opt_threads
    if ((max_threads <= 0)); then
        local available_memory=1024
        local free_out
        free_out=$(free -m 2>/dev/null | awk '/Mem:/ {print $7}')
        [[ -n $free_out ]] && available_memory=$free_out
        max_threads=$((available_memory / 28))
        ((max_threads > 18)) && max_threads=18
        ((max_threads < 3)) && max_threads=3
    fi
    echo -e "${Font_Cyan}开始回程追踪: ${rmtestnum} 个目标 (IPv${ipver}, TCP:80, 并发 ${max_threads})${Font_Suffix}" >&2
    if ((rmtestnum == 0)); then
        echo -e "${Font_Red}内部错误: 目标数为 0, 请检查省份参数${Font_Suffix}" >&2
        exit 1
    fi

    local i=0 current_threads=0 domain carrier_str
    for prov in "${provs[@]}"; do
        for carrier_str in ct cu cm; do
            i=$((i + 1))
            domain="${prov}-${carrier_str}-v${ipver}.ip.zstaticcdn.com"
            nexttrace_route "$domain" "$i" "$ipver" > "$res_dir/r.$i.txt" &
            echo -e "  ${Font_Yellow}→ [$i/$rmtestnum] ${PROV[$prov]%%|*} $domain${Font_Suffix}" >&2
            current_threads=$((current_threads + 1))
            if ((current_threads >= max_threads)); then
                wait -n
                current_threads=$((current_threads - 1))
            else
                sleep 2
            fi
        done
    done
    wait

    aggregate_results "$rmtestnum" "$res_dir"
    display_results "$ipver" "$rmtestnum"
}

selftest(){
    # 用模拟数据验证聚合/分类/输出链路 (不联网, 不下载 nexttrace)

    # 回归断言: build_targets 必须正确写入全局变量(曾在 $() 子 shell 中调用导致丢失)
    opt_prov="gd,zj"
    build_targets
    if [[ $rmtestnum -ne 6 || ${rmcode[1]} != "广东" || ${rmcode[4]} != "浙江" || ${TARGET_PROVS[1]} != "zj" ]]; then
        echo -e "${Font_Red}断言失败: build_targets 全局状态不正确 (rmtestnum=$rmtestnum)${Font_Suffix}" >&2
        exit 1
    fi
    opt_prov=""
    build_targets
    [[ $rmtestnum -eq 9 && ${TARGET_PROVS[0]} == "bj" ]] || { echo "断言失败: 默认目标数" >&2; exit 1; }

    rmtestnum=9
    rmcode[1]="北京" rmcode[2]="北京" rmcode[3]="北京"
    rmcode[4]="上海" rmcode[5]="上海" rmcode[6]="上海"
    rmcode[7]="广东" rmcode[8]="广东" rmcode[9]="广东"
    local res_dir="$tmp_dir/v4"
    mkdir -p "$res_dir"
    # 1: 163 骨干
    cat > "$res_dir/r.1.txt" <<'EOF'
|1|1|0.31ms|192.168.1.1|AS0|||
|1|2|1.20ms|45.61.44.1|AS53667|||
|1|3|0.98ms|198.51.100.9|AS174|||
|1|4|142.11ms|202.97.27.201|AS4134||中国 上海 电信|
|1|5|143.05ms|202.97.33.101|AS4134||中国 上海 电信|
|1|6|150.22ms|101.95.101.2|AS4134||中国 上海 电信|
EOF
    # 2: CN2 GIA (59.43 骨干)
    cat > "$res_dir/r.2.txt" <<'EOF'
|2|1|0.30ms|10.0.0.1|AS0|||
|2|2|1.10ms|23.105.12.1|AS53667|||
|2|3|0.90ms|198.51.100.1|AS1299|||
|2|4|130.11ms|59.43.182.201|AS4809||中国 上海 电信|
|2|5|131.50ms|59.43.130.2|AS4809||中国 上海 电信|
EOF
    # 3: CUII 9929
    cat > "$res_dir/r.3.txt" <<'EOF'
|3|1|0.29ms|10.0.0.1|AS0|||
|3|2|0.87ms|64.44.100.1|AS20473|||
|3|3|0.95ms|218.105.100.9|AS10099|||
|3|4|148.30ms|219.158.100.1|AS9929||中国 北京 联通|
|3|5|149.10ms|219.158.200.2|AS9929||中国 北京 联通|
EOF
    # 4: CMIN2
    cat > "$res_dir/r.4.txt" <<'EOF'
|4|1|0.35ms|172.16.0.1|AS0|||
|4|2|1.02ms|103.10.20.1|AS45102|||
|4|3|1.20ms|223.120.100.1|AS58807||中国 上海 移动|
|4|4|35.80ms|223.120.200.2|AS58807||中国 上海 移动|
EOF
    # 5: 4837
    cat > "$res_dir/r.5.txt" <<'EOF'
|5|1|0.28ms|10.0.0.1|AS0|||
|5|2|0.91ms|64.44.200.1|AS20473|||
|5|3|148.90ms|219.158.30.1|AS4837||中国 上海 联通|
|5|4|150.10ms|219.158.40.2|AS4837||中国 上海 联通|
EOF
    # 6: Hidden (全程境外无中国节点)
    cat > "$res_dir/r.6.txt" <<'EOF'
|6|1|0.30ms|10.0.0.1|AS0|||
|6|2|1.00ms|45.61.50.1|AS53667|||
|6|3|2.00ms|104.16.0.1|AS13335|||
EOF
    # 7/8/9: 空结果
    : > "$res_dir/r.7.txt"; : > "$res_dir/r.8.txt"; : > "$res_dir/r.9.txt"
    aggregate_results "$rmtestnum" "$res_dir"
    display_results 4 "$rmtestnum"
    echo "selftest 完成" >&2
    cleanup
}

main(){
    trap cleanup INT TERM EXIT
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/nq-route.XXXXXX")

    get_opts "$@"

    # 自测: 纯 bash 逻辑验证, 不依赖平台与网络
    if ((opt_selftest)); then
        selftest
    fi

    check_env

    echo -e "${Font_Cyan}${Font_B}"
    echo "  回程路由测试 · NodeQuality 精简版  (v${script_version})"
    echo "  仅回程路由 | 无环境侵入 | 不上传数据"
    echo -e "${Font_Suffix}"

    install_nexttrace

    build_targets

    local first_prov="${TARGET_PROVS[0]}"

    if [[ -n $opt_ipv ]]; then
        # 指定单栈
        if ! check_family "$opt_ipv" "$first_prov"; then
            echo -e "${Font_Red}错误: IPv${opt_ipv#-} 网络不可用${Font_Suffix}" >&2
            exit 1
        fi
        run_family "${opt_ipv#-}" "${TARGET_PROVS[@]}"
    else
        # 自动: v4 必测, v6 可用则测
        if check_family -4 "$first_prov"; then
            run_family 4 "${TARGET_PROVS[@]}"
        else
            echo -e "${Font_Red}错误: IPv4 网络不可用${Font_Suffix}" >&2
            exit 1
        fi
        if check_family -6 "$first_prov"; then
            echo "" >&2
            run_family 6 "${TARGET_PROVS[@]}"
        else
            echo -e "${Font_Yellow}IPv6 不可用, 跳过${Font_Suffix}" >&2
        fi
    fi
}

main "$@"
