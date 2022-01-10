#!/usr/bin/env bash

################ Script Info ################		

## Program: 	Auto Script V1.0
## Author:  	Nigori
## Date:    	2020-01-09
## Description: 在脚本所在目录下创建redis集群或单例服务
## version: 	1.0

################ Env Define ################

cat <<'EOF'
                       _   _ _                  _
                      | \ | (_) __ _  ___  _ __(_)
                      |  \| | |/ _` |/ _ \| '__| |
                      | |\  | | (_| | (_) | |  | |
                      |_| \_|_|\__, |\___/|_|  |_|
                               |___/
                  :: redis docker tools ::  (v1.0.0.RELEASE)     



EOF

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:~/sbin
LANG=C
export PATH
export LANG

set -e
# set -o pipfail

# info级别的日志 []<-(msg:String)
log_info(){
	echo "\033[32m[info] $* \033[0m" >&2
}
# error级别的日志 []<-(msg:String)
log_error(){
	# todo [error]用红色显示
	local msg=$1 # 将要输出的日志内容
	if [[ x"${msg}" != x"" ]];then
		echo "\033[31m[error] $* \033[0m" >&2
	fi
}


OS="`uname`"
case $OS in
  'Linux')
    OS='Linux'
    alias ls='ls --color=auto'
    ;;
  'FreeBSD')
    OS='FreeBSD'
    alias ls='ls -G'
    ;;
  'WindowsNT')
    OS='Windows'
    ;;
  'Darwin') 
    OS='Mac'
    ;;
  'SunOS')
    OS='Solaris'
    ;;
  'AIX') ;;
  *) ;;
esac

if [ "Mac" != ${OS} -a "Linux" != ${OS} ];then
	log_error "The current operating system is not supported!"
fi

if [ "Linux" == ${OS} ]; then
	LOCAL_IP=`ifconfig eth0|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d "addr:"​`
elif [[ "Mac" == ${OS} ]]; then
	LOCAL_IP=`ifconfig en0|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d "addr:"​`
fi

SCRIPT_DIR=$(cd $(dirname $0); pwd) # 脚本所在目录

# 创建redis配置模版 []<-(msg:String msg:String)
function create_redis_single_tmpl(){
local tmpl_name=$1

if [ ! -f ${SCRIPT_DIR}/${tmpl_name} ];then
	log_info "创建文件：${SCRIPT_DIR}/${tmpl_name}"
cat <<'EOF'> ${SCRIPT_DIR}/${tmpl_name}
bind 0.0.0.0
protected-mode no
port 6379
timeout 0
save 900 1 # 900s内至少一次写操作则执行bgsave进行RDB持久化
save 300 10
save 60 10000
rdbcompression yes
dbfilename dump.rdb
dir ${SCRIPT_DIR}/data
appendonly yes
appendfsync everysec
requirepass ${PASSWORD}
EOF
fi

}

# 创建集群redis配置模版 []<-(msg:String)
function create_redis_cluster_tmpl(){
local tmpl_name=$1
cat <<'EOF'> ${SCRIPT_DIR}/${tmpl_name}
port ${PORT}
dir ${SCRIPT_DIR}/data
appendonly yes
protected-mode no
cluster-enabled yes
cluster-node-timeout 5000
cluster-announce-ip ${CLUSTER_ANNOUNCE_IP}
cluster-announce-port ${PORT}
cluster-announce-bus-port 1${PORT}
cluster-config-file nodes-${PORT}.conf
EOF
}

# 创建指定范围的目录配置 []<-(msg:Integer msg:Integer msg:String)
function create_all_data_dir(){
	for port in `seq $2 $3`; do create_data_dir $1 $port
	done
}

# 创建目录配置 []<-(msg:Integer msg:String)
function create_data_dir(){
	local tmpl_name=$1
	local port=$2
	mkdir -p ${SCRIPT_DIR}/${port}/conf \
	&& PORT=${port} PASSWORD=${PASSWORD} CLUSTER_ANNOUNCE_IP=${LOCAL_IP}  envsubst < ${SCRIPT_DIR}/${tmpl_name} > ${SCRIPT_DIR}/${port}/conf/redis.conf \
	&& mkdir -p ${SCRIPT_DIR}/${port}/data; \
}

# 创建指定范围的服务yaml []<-(msg:String msg:Integer msg:Integer)
function create_docker_compose_yaml(){
	local yaml_file_name=$1
	local start_port=$2
	local end_port=$3

	if [ ! -n "${end_port}" ]; then
	  local end_port=$2
	fi

cat <<'EOF'> ${SCRIPT_DIR}/${yaml_file_name}
version: "3.8"
networks:
    app-net:
      external: true
services:
EOF

cat <<'EOF'> ${SCRIPT_DIR}/docker-compose.tmpl
  redis-${PORT}:
    cap_add:
      - ALL
    container_name: redis-${PORT}
    image: redis:${REDIS_VERSION}
    ports:
      - "${PORT}:${PORT}"
      - "1${PORT}:1${PORT}"
    networks:
      - app-net
    volumes:
      - ${REDIS_CLUSTER_DIR}/${PORT}/data:/data
      - ${REDIS_CLUSTER_DIR}/${PORT}/conf:/etc/redis
      - ${REDIS_CLUSTER_LOG}/${PORT}:/var/log/redis-cluster/${PORT}
    restart: always
    privileged: true
    command: redis-server /etc/redis/redis.conf
EOF


for port in `seq ${start_port} ${end_port}`; do
	PORT=${port} REDIS_VERSION=${REDIS_VERSION} REDIS_CLUSTER_DIR=${SCRIPT_DIR} REDIS_CLUSTER_LOG=${REDIS_LOG_DIR} \
	 envsubst < ${SCRIPT_DIR}/docker-compose.tmpl >> ${SCRIPT_DIR}/${yaml_file_name}
done
rm -rf ${SCRIPT_DIR}/docker-compose.tmpl
}

# 创建docker环境配置 []<-()
function create_env_config(){
	echo REDIS_VERSION=${REDIS_VERSION} > ${SCRIPT_DIR}/.env
	echo REDIS_CLUSTER_DIR=${SCRIPT_DIR}/ >> ${SCRIPT_DIR}/.env
	echo REDIS_CLUSTER_LOG=${REDIS_LOG_DIR} >> ${SCRIPT_DIR}/.env
}

# 运行docker-compose启动redis容器 []<-(msg:String)
function run_docker_compose(){
	docker-compose --env-file ${SCRIPT_DIR}/.env -f ${SCRIPT_DIR}/$1 up -d
}

# 创建集群 []<-(msg:Integer msg:Integer)
function create_cluster(){
	local start_port=$1
	local end_port=$2
	exist=$(docker inspect --format '{{.State.Running}}' redis-${start_port})

	if [[${exist}!='true']];
	then
	    sleep 500
	else
	    echo 'redis容器启动成功！'
	    IP_RESULT=""
	    CONTAINER_IP=""
	    for port in `seq ${start_port} ${end_port}`;
	    do
	    #CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' redis-${port})
	    IP_RESULT=${IP_RESULT}${LOCAL_IP}":"${port}" "
	    done
	fi
	echo "获取redis容器ip和端口号：" ${IP_RESULT}

	docker run --rm -it inem0o/redis-trib create --replicas 1 ${IP_RESULT}
}

# 启动单例redis
function start_single(){
	local single_port=6379
	local single_docker_yaml=redis-single.yaml
	local single_conf_tmpl=redis-single-conf.tmpl

	log_info "single redis server step 1 -> Create configuration template------"
	create_redis_single_tmpl ${single_conf_tmpl}
	log_info "single redis server step 2 -> Create data configuration mount directory------"
	create_data_dir ${single_conf_tmpl} ${single_port}
	log_info "single redis server step 3 -> Create ${single_docker_yaml} file------"
	create_docker_compose_yaml ${single_docker_yaml} ${single_port}
	log_info "single redis server step 4 -> Create environment profile------"
	create_env_config
	log_info "single redis server step 5 -> Execute ${single_docker_yaml} to start the redis container------"
	run_docker_compose ${single_docker_yaml}
}

# 启动集群redis
function start_cluster(){
	local start_port=7000
	local end_port=7005
	local cluster_docker_yaml=redis-cluster.yaml
	local cluster_conf_tmpl=redis-cluster-conf.tmpl

	log_info "cluster redis server step 1 -> Create configuration template------"
	create_redis_cluster_tmpl ${cluster_conf_tmpl}
	log_info "cluster redis server step 2 -> Create data configuration mount directory------"
	create_all_data_dir ${cluster_conf_tmpl} ${start_port} ${end_port}
	log_info "cluster redis server step 3 -> Create ${cluster_docker_yaml} file------"
	create_docker_compose_yaml ${cluster_docker_yaml} ${start_port} ${end_port}
	log_info "cluster redis server step 4 -> Create environment profile------"
	create_env_config
	log_info "cluster redis server step 5 -> Execute ${cluster_docker_yaml} to start the redis container------"
	run_docker_compose ${cluster_docker_yaml}
	log_info "cluster redis server step 6 -> Start cluster------"
	create_cluster ${start_port} ${end_port}
}

function agree(){
	read -r -p "Do you agree with the above configuration? [Y/n] " input
	case $input in
	    [yY][eE][sS]|[yY])
			;;

	    [nN][oO]|[nN])
			exit 0
	       	;;

	    *)
			echo "Invalid input..."
			exit 1
			;;
	esac
}

function print_single_config(){
	log_info "single redis config info: "
	log_info "redis version: ${REDIS_VERSION}"
	log_info "redis port: ${SINGLE_PORT}"
	log_info "redis password: ${PASSWORD}"
	log_info "redis local ip: ${LOCAL_IP}"
	log_info "redis work dir: ${SCRIPT_DIR}"
	log_info "redis log dir: ${REDIS_LOG_DIR}"
}

function print_cluster_config(){
	log_info "cluster redis config info: "
	log_info "redis version: ${REDIS_VERSION}"
	log_info "redis start port: ${CLUSTER_START_PORT}"
	log_info "redis end port: ${CLUSTER_END_PORT}"
	log_info "redis password: ${PASSWORD}"
	log_info "redis local ip: ${LOCAL_IP}"
	log_info "redis work dir: ${SCRIPT_DIR}"
	log_info "redis log dir: ${REDIS_LOG_DIR}"
}

MODE="single"                               # 启动集群模式，single：单例模式；cluster：集群模式
REDIS_VERSION=6.0.9                         # redis版本
PASSWORD=kaixin                             # redis密码
REDIS_LOG_DIR=${SCRIPT_DIR}/log             # redis宿主机日志目录
SINGLE_PORT=6379
CLUSTER_START_PORT=7000
CLUSTER_END_PORT=7005
SERVER_NUM=5


if [ x"$1" = x ] ;then
	MODE="single"
else
	if [ "single" == $1 ]; then
		MODE="single"
	elif [[ "cluster" == $1 ]]; then
		MODE="cluster"
	else
		log_error "Unknown command"
		exit 1
	fi
fi

set `getopt v:port:p:l:c: "$@"`
while [ -n "$2" ]
do
    case "$2" in 
    -v)
        REDIS_VERSION=${3}  # redis版本
        shift;;
    -p)
        PASSWORD=${3}  # redis密码
        shift;;
    -l)
        REDIS_LOG_DIR=${3}  # 宿主机日志目录
        shift;;
    --port)
        # 端口
        if [ "single" == ${MODE} ]; then
			SINGLE_PORT=${3}
		elif [[ "cluster" == ${MODE} ]]; then
			CLUSTER_START_PORT=${3}
		fi
        shift;;
    -c)
        if [[ "cluster" == ${MODE} ]]; then
        	count=5
        	if [[ x"$3" != x && ${count} -lt ${3} ]] ;then
        		count=${3}
        	fi
        	SERVER_NUM=${count}
		fi
        shift;;

    --)
        shift
        break;;
    *)
        echo "$1 is not an option";;
    esac
    shift
done

# 初始化
function init(){
	if [ "single" == ${MODE} ]; then
		SCRIPT_DIR=${SCRIPT_DIR}/redis-single
		print_single_config
	elif [[ "cluster" == ${MODE} ]]; then
		SCRIPT_DIR=${SCRIPT_DIR}/redis-cluster
		CLUSTER_END_PORT=$(expr ${CLUSTER_START_PORT} + ${SERVER_NUM})
		print_cluster_config
	fi
	agree

	mkdir -p ${SCRIPT_DIR}
	cd ${SCRIPT_DIR}
}

# 主函数 []<-()
function main(){
	init $@
	if [ "single" == ${MODE} ]; then
		log_info "Create a singleton service!"
		start_single $@
	elif [[ "cluster" == ${MODE} ]]; then
		log_info "Create cluster service!"
		start_cluster $@
	fi
}

main $@

exit 0