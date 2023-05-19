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

function create_input_events_links {
	local inputs=

	OIFS=${IFS}
	IFS=','

	for ent in ${SEAT_DEVS}; do
		echo "${ent}" | egrep -q "^input[0-9]+$" || continue
		inputs="${inputs}$(cat /sys/class/input/${ent}/name):$(basename /sys/class/input/${ent}/event*)\n"
	done

	IFS=${OIFS}

	for input in {keyboard,mouse}; do
		xml_input_path="$(xmllint --xpath "//domain/devices/input[@type='evdev']/source/@dev" ${VM_XML_FILE_PATH} | grep "/${input}-" | cut -f 2 -d = | sed 's/"//g')"
		if [ -z "${xml_input_path}" ]; then
			continue
		fi

		if [ "${STATE_PATH}" != "$(dirname ${xml_input_path})" ]; then
			echo "${STATE_PATH} and $(dirname ${xml_input_path}) differ"
			exit 1
		fi

		event_fd=$(echo -e "${inputs::-2}" | grep -i " ${input}:" | cut -f 2 -d :)
		ln -s /dev/input/${event_fd} ${xml_input_path}
	done
}

function bdf_to_nodedev {
	echo "pci_$(echo $1 | sed 's/[:\.]/_/g')"
}

function detach_pcie_pt_devs {
	OIFS=${IFS}
	IFS=","
	for bdf in ${VM_PCIE_PT_BFDS}; do
		local dev=$(bdf_to_nodedev ${bdf})

		virsh nodedev-detach ${dev}
	done
	IFS=${OIFS}
}

function reattach_pcie_pt_devs {
	OIFS=${IFS}
	IFS=","
	for bdf in ${VM_PCIE_PT_BFDS}; do
		local dev=$(bdf_to_nodedev ${bdf})

		virsh nodedev-reattach ${dev}
	done
	IFS=${OIFS}
}

function pcie_pt_dev_has_active_gpu {
	local ret_val=0
	local gpus_pci_addr=
	OIFS=${IFS}
	IFS=","

	for ent in ${SEAT_DEVS}; do
		echo "${ent}" | egrep -q "^card[0-9]+$" || continue
		gpus_pci_addr="${gpus_pci_addr}$(realpath /sys/class/drm/${ent}/device/ | xargs basename)\n"
	done

	for bdf in ${VM_PCIE_PT_BFDS}; do
		class=$(cat /sys/bus/pci/devices/${bdf}/class)

		if [ "${class}" != "0x030000" ]; then
			continue
		else
			echo -e "${gpus_pci_addr::-2}" | egrep -q "^${bdf}$"

			if [ $? -eq 0 ]; then
				ret_val=1
				break
			fi
		fi
	done
	IFS=${OIFS}

	return ${ret_val}
}

function unbind_active_gpu {
	pcie_pt_dev_has_active_gpu
	if [ $? -eq 0 ]; then
		return
	fi

	rc-config stop display-manager

	for vtcon in $(find /sys/class/vtconsole -name "vtcon*" ! -type d); do
		grep -q "frame buffer device$" ${vtcon}/name || continue
		echo 0 > ${vtcon}/bind
	done

	# unbind efi fb
	echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind
}

function rebind_active_gpu {
	pcie_pt_dev_has_active_gpu
	if [ $? -eq 0 ]; then
		return
	fi

	for vtcon in $(find /sys/class/vtconsole -name "vtcon*" ! -type d); do
		grep -q "frame buffer device$" ${vtcon}/name || continue
		echo 1 > ${vtcon}/bind
	done

	echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/bind

	rc-config start display-manager
}
