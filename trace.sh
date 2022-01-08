#! /bin/bash
if [ "$#" -lt 2 ];
then
    echo -e "请规范参数格式: \033[1;34;41m -a 目标ip\033[0m"
else
    while [ "$#" -ge 1 ];do
        case $1 in
            -a)
                shift
                iplise=$1
                shift
        esac
    done
    if [ ! -x /usr/bin/mtr ] || [ ! -x /sbin/mtr ];
    then
        echo "开始安装mtr命令..."
        apt update -y && apt install mtr -y
        yum update -y && yum install mtr -y
    else
        echo "mtr已安装..."
        
    fi
    clear
    echo -e "\n正在测试,请稍等..."
    echo -e "——————————————————————————————\n"
    mtr -r --n --tcp ${iplise} > mtr.log
    cat ./mtr.log
    echo -e "——————————————————————————————\n"
     grep -q "59\.43\." mtr.log
    if [ $? == 0 ];then
        grep -q "202\.97\."  mtr.log
        if [ $? == 0 ];then
            echo -e "目标地址:[${iplise}]\t回程线路:\033[1;32m电信CN2 GT(AS4809)\033[0m"
        else
            echo -e "目标地址:[${iplise}]\t回程线路:\033[1;31m电信CN2 GIA(AS4809)\033[0m"
        fi
    else
        grep -q "202\.97\."  mtr.log
        if [ $? == 0 ];then
            grep -q "218\.105\." mtr.log
            if [ $? == 0 ];then
                echo -e "目标地址:[${iplise}]\t回程线路:\033[1;31m联通精品网(AS9929)\033[0m"
            else
                grep -q "219\.158\." mtr.log
                if [ $? == 0 ];then
                    echo -e "目标地址:[${iplise}]\t回程线路:\033[1;33m联通169(AS4837)\033[0m"
                else
                    echo -e "目标地址:[${iplise}]\t回程线路:\033[1;34m电信163(AS4134)\033[0m"
                fi
            fi
        else
            grep -q "219\.158\."  mtr.log
            if [ $? == 0 ];then
                grep -q "218\.105\." mtr.log
                if [ $? == 0 ];then
                    echo -e "目标地址:[${iplise}]\t回程线路:\033[1;31m联通精品网(AS9929)\033[0m"
                else
                    echo -e "目标地址:[${iplise}]\t回程线路:\033[1;33m联通169(AS4837)\033[0m"
                fi
                
            else
                grep -q "223\.120\."  mtr.log
                if [ $? == 0 ];then
                    echo -e "目标地址:[${iplise}]\t回程线路:\033[1;35m移动CMI(AS9808)\033[0m"
                else
                    grep -q "221\.183\." mtr.log
                    if [ $? == 0 ];then
                        echo -e "目标地址:[${iplise}]\t回程线路:\033[1;35m移动CMI(AS9808)\033[0m"
                    else
                        grep -q "218\.105\." mtr.log
                        if [ $? == 0 ];then
                            echo -e "目标地址:[${iplise}]\t回程线路:\033[1;31m联通精品网(AS9929)\033[0m"
                        else
                            grep -q "219\.158\." mtr.log
                            if [ $? == 0 ];then
                                echo -e "目标地址:[${iplise}]\t回程线路:\033[1;33m联通169(AS4837)\033[0m"
                            else
                                grep -q "219\.158\." mtr.log
                                if [ $? == 0 ];then
                                    echo -e "目标地址:[${iplise}]\t回程线路:\033[1;34m电信163(AS4134)\033[0m"
                                else
                                    echo -e "目标地址:[${iplise}]\t回程线路:其他"
                                fi
                            fi
                        fi
                        
                    fi
                fi
            fi
        fi
    fi
    rm -f mtr.log
fi
