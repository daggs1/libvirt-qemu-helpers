#!/bin/bash

function init_base_vars {
	local GST_NAME="$1"
	local STATE="$2"
	local STAGE="$3"
	local LOGS_PATH="/var/log/libvirt/qemu/helpers"
	local STATE_PATH="/var/lib/libvirt/helpers_state/${GST_NAME}"
	local CFG_PATH="/etc/libvirt/hooks/qemu.d"
	local curr_pid=$(ps aux | grep " start ${GST_NAME}" | grep -v grep | awk '{print $2}')
	local EXEC_USER=$(ps -o user= -p ${curr_pid})

	for var in {GST_NAME,STATE,STAGE,EXEC_USER,CFG_PATH,STATE_PATH,LOGS_PATH}; do
		echo "${var}=$(eval echo \${${var}})"
	done
}

function init_log {
	local log_path="${LOGS_PATH}/${GST_NAME}.log"

	mkdir -p $(dirname ${log_path})
	exec 2> >(tee -a -i "${log_path}")
	set -x
	exec >> "${log_path}"
	echo "log started at $(date)"
}

