#!/bin/bash

function get_pt_usb_hubs_files {
	local GST_NAME="$1"
	local STATE_PATH="$2"

	echo "pt_usb_hubs_tmp_file_path=\"/tmp/pt_usb_hubs-${GST_NAME}\" pt_usb_hubs_file_path=\"${STATE_PATH}/pt_usb_hubs\""
}

function get_seat_devs_files {
	local GST_NAME="$1"
	local STATE_PATH="$2"

	echo "seat_devs_tmp_file_path=\"/tmp/seat_devs-${GST_NAME}\" seat_devs_file_path=\"${STATE_PATH}/seat_devs\""
}

function init_base_vars {
	local GST_NAME="$1"
	local STATE="$2"
	local STAGE="$3"
	local LOGS_PATH="/var/log/libvirt/qemu/helpers"
	local STATE_PATH="/var/lib/libvirt/helpers_state/${GST_NAME}"
	local CFG_PATH="/etc/libvirt/hooks/qemu.d"
	local curr_pid=$(ps aux | grep " start ${GST_NAME}" | grep -v grep | awk '{print $2}')
	local EXEC_USER=$(ps -o user= -p ${curr_pid} 2>/dev/null)
	local VM_XML_FILE_PATH=
	eval $(get_seat_devs_files ${GST_NAME} ${STATE_PATH})
	eval $(get_pt_usb_hubs_files ${GST_NAME} ${STATE_PATH})

	local curr_seat_devs_file_path=${seat_devs_tmp_file_path}
	local curr_pt_usb_hubs_file_path=${pt_usb_hubs_tmp_file_path}

	if [ ! -f "${curr_seat_devs_file_path}" ]; then
		curr_seat_devs_file_path=${seat_devs_file_path}
	fi

	if [ ! -f "${curr_pt_usb_hubs_file_path}" ]; then
		curr_pt_usb_hubs_file_path=${pt_usb_hubs_file_path}
	fi

	local SEAT_DEVS=$(cat ${curr_seat_devs_file_path} 2>/dev/null)
	local USB_PT_DATA=$(cat ${curr_pt_usb_hubs_file_path} 2>/dev/null)
	local VM_PCIE_PT_BFDS=

	if [ "${STATE}" != "running" -a "${STAGE}" != "usb_pre_hotplug_scan" ]; then
		local SEAT_DEVS=$(cat ${curr_seat_devs_file_path} 2>/dev/null)
		local cmd

		if [ "${STATE}" = "init" -a "${STAGE}" = "none" ]; then
			VM_XML_FILE_PATH=-
			cmd="virsh --connect qemu:///system dumpxml ${GST_NAME}"
		else
			local xmls_path="$(realpath ${CFG_PATH}/../../qemu)"
			OIFS=${IFS}
			IFS=$'\n'

			for xml_file_path in $(find ${xmls_path} -name "*.xml" -type f); do
				xmllint --xpath "//domain/name/text()" ${xml_file_path} 2>/dev/null | egrep -q "^${GST_NAME}$" || continue
				VM_XML_FILE_PATH=${xml_file_path}
				break
			done

			OIFS=${OIFS}
			cmd="cat ${VM_XML_FILE_PATH}"
		fi
	fi

	local VM_PCIE_PT_BFDS=$(eval ${cmd} | gather_pcie_pt_bdfs)
	for var in {GST_NAME,STATE,STAGE,EXEC_USER,CFG_PATH,STATE_PATH,LOGS_PATH,VM_XML_FILE_PATH,VM_PCIE_PT_BFDS,SEAT_DEVS,USB_PT_DATA}; do
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

	eval $(get_seat_devs_files ${GST_NAME} ${STATE_PATH})
	eval $(get_pt_usb_hubs_files ${GST_NAME} ${STATE_PATH})

	if [ ! -f "${seat_devs_file_path}" -a -f "${seat_devs_tmp_file_path}" ]; then
		mv ${seat_devs_tmp_file_path} ${seat_devs_file_path}
	fi

	if [ ! -f "${pt_usb_hubs_file_path}" -a -f "${pt_usb_hubs_tmp_file_path}" ]; then
		mv ${pt_usb_hubs_tmp_file_path} ${pt_usb_hubs_file_path}
	fi
}

function release_state {
	umount ${STATE_PATH}
}

function gather_pcie_pt_bdfs {
	local bdfs=
	local prefix="//domain/devices/hostdev[@type='pci']/source/address"
	local data=
	while read line; do
		data="${data}\n${line}"
	done < "${1:-/dev/stdin}"

	OIFS=${IFS}
	IFS=","

	for pcie in $(echo -e "${data}" | xmllint --xpath "${prefix}/@domain | ${prefix}/@bus | ${prefix}/@slot | ${prefix}/@function" - 2>/dev/null | cut -f 2 -d = | sed 's/"//g;s/0x//g' | sed '0~4 a\,\'); do
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
	local efifb_path="/sys/bus/platform/drivers/efi-framebuffer/"

	pcie_pt_dev_has_active_gpu
	if [ $? -eq 0 ]; then
		return
	fi

	rc-config stop display-manager

	for vtcon in $(find /sys/class/vtconsole -name "vtcon*" ! -type d); do
		grep -q "frame buffer device$" ${vtcon}/name || continue
		echo 0 > ${vtcon}/bind
	done

	if [ -d "${efifb_path}" ]; then
		# unbind efi fb
		echo efi-framebuffer.0 > ${efifb_path}/unbind
	fi
}

function rebind_active_gpu {
	local efifb_path="/sys/bus/platform/drivers/efi-framebuffer/"

	pcie_pt_dev_has_active_gpu
	if [ $? -eq 0 ]; then
		return
	fi

	for vtcon in $(find /sys/class/vtconsole -name "vtcon*" ! -type d); do
		grep -q "frame buffer device$" ${vtcon}/name || continue
		echo 1 > ${vtcon}/bind
	done

	if [ -d "${efifb_path}" ]; then
		echo efi-framebuffer.0 > ${efifb_path}/bind
	fi

	rc-config start display-manager
}

vm_name=$1
case $(basename $0) in
	start_vm)
		eval $(get_seat_devs_files ${vm_name} /dev/null)
		eval $(get_pt_usb_hubs_files ${vm_name} /dev/null)

		for module in {tun,kvm_amd,vhost_net}; do
			sudo modprobe ${module} || exit $?
		done
		sudo rc-config start libvirtd || exit $?
		sleep 1s
		virsh_params="--connect qemu:///system -d 4"

		loginctl seat-status | egrep "(MASTER|Keyboard|Mouse)" | egrep -v "Control" | cut -f 2 -d : | awk '{print $1}' | tr '\n' ',' | sed 's/,$//g' > ${seat_devs_tmp_file_path}
		echo "${PT_USB_HUBS}" > ${pt_usb_hubs_tmp_file_path}

		export $(init_base_vars ${vm_name} init none)
		cmd="bash"
		virsh ${virsh_params} dumpxml ${vm_name} | pcie_pt_dev_has_active_gpu
		if [ $? -eq 1 ]; then
			cmd="at -m now"
		fi

		echo "virsh ${virsh_params} start ${vm_name}" | ${cmd}
	;;

	handle_udev_usb_hp)
		bus_num=$(echo "${BUSNUM}" | sed "s/^0\+//g")
		dev_num=$(echo "${DEVNUM}" | sed "s/^0\+//g")

		for vm_name in $(virsh --connect qemu:///system list | egrep " running$" | awk '{print $2}'); do
			export $(init_base_vars ${vm_name} init none)
			matched=0

			OIFS=${IFS}
			IFS=","

			for hub in ${USB_PT_DATA}; do
				echo "${DEVPATH}" | egrep -q "/${hub}/" || continue
				if [ ! -z "${bus_num}" -o ! -z "${dev_num}" ]; then
					matched=1
					if [ "${ACTION}" = "add" ]; then
						virsh --connect qemu:///system attach-device ${vm_name} /dev/stdin << VIRSHEOS
							<hostdev mode='subsystem' type='usb'>
								<source>
									<address type='usb' bus='${bus_num}' device='${dev_num}'/>
								</source>
							</hostdev>
VIRSHEOS
					elif [ "${ACTION}" = "remove" ]; then
						virsh --connect qemu:///system detach-device ${vm_name} /dev/stdin << VIRSHEOS
							<hostdev mode='subsystem' type='usb'>
								<source>
									<address type='usb' bus='${bus_num}' device='${dev_num}'/>
								</source>
							</hostdev>
VIRSHEOS
					else
						matched=0
					fi
				fi
			done
			IFS=${OIFS}

			if [ ${matched} -eq 1 ]; then
				break
			fi
		done
	;;
esac
