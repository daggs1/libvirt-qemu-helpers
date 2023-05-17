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
	local VM_XML_FILE_PATH=
	local seat_devs_file_path="/tmp/seat_devs-${GST_NAME}"
	local SEAT_DEVS=$(cat ${seat_devs_file_path} 2>/dev/null)

	rm -rf ${seat_devs_file_path} 2>/dev/null
	local xmls_path="${CFG_PATH}/../../qemu"
	OIFS=${IFS}
	IFS=$'\n'

	for xml_file_path in $(find ${xmls_path} -name "*.xml" -type f); do
		xmllint --xpath "//domain/name/text()" ${xml_file_path} 2>/dev/null | egrep -q "^${GST_NAME}$" || continue
		VM_XML_FILE_PATH=${xml_file_path}
		break
	done

	OIFS=${OIFS}

	local VM_PCIE_PT_BFDS=$(export VM_PCIE_PT_BFDS; gather_pcie_pt_bdfs)
	for var in {GST_NAME,STATE,STAGE,EXEC_USER,CFG_PATH,STATE_PATH,LOGS_PATH,VM_XML_FILE_PATH,VM_PCIE_PT_BFDS,SEAT_DEVS}; do
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

function prep_state {
	mkdir -p ${STATE_PATH}
	mount -t tmpfs -o size=4K tmpfs ${STATE_PATH}
}

function release_state {
	umount ${STATE_PATH}
}

function gather_pcie_pt_bdfs {
	local bdfs=
	local prefix="//domain/devices/hostdev[@type='pci']/source/address"
	OIFS=${IFS}
	IFS=","

	for pcie in $(xmllint --xpath "${prefix}/@domain | ${prefix}/@bus | ${prefix}/@slot | ${prefix}/@function" ${VM_XML_FILE_PATH} 2>/dev/null | cut -f 2 -d = | sed 's/"//g;s/0x//g' | sed '0~4 a\,\'); do
		bdfs="${bdfs},$(echo "${pcie}" | xargs | sed 's/ /./3;s/ /:/g')"
	done

	IFS=${OIFS}
	echo ${bdfs:1}
}
