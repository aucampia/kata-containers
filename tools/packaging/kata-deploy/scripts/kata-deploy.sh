#!/usr/bin/env bash
# Copyright (c) 2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o pipefail
set -o nounset

crio_drop_in_conf_dir="/etc/crio/crio.conf.d/"
crio_drop_in_conf_file="${crio_drop_in_conf_dir}/99-kata-deploy"
crio_drop_in_conf_file_debug="${crio_drop_in_conf_dir}/100-debug"
containerd_conf_file="/etc/containerd/config.toml"
containerd_conf_file_backup="${containerd_conf_file}.bak"

shims=(
	"fc"
	"qemu"
	"qemu-nvidia-gpu"
	"qemu-tdx"
	"qemu-sev"
	"qemu-snp"
	"clh"
	"dragonball"
)

default_shim="qemu"

# If we fail for any reason a message will be displayed
die() {
        msg="$*"
        echo "ERROR: $msg" >&2
        exit 1
}

function print_usage() {
	echo "Usage: $0 [install/cleanup/reset]"
}

function get_container_runtime() {

	local runtime=$(kubectl get node $NODE_NAME -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
	if [ "$?" -ne 0 ]; then
                die "invalid node name"
	fi
	if echo "$runtime" | grep -qE 'containerd.*-k3s'; then
		if systemctl is-active --quiet rke2-agent; then
			echo "rke2-agent"
		elif systemctl is-active --quiet rke2-server; then
			echo "rke2-server"
		elif systemctl is-active --quiet k3s-agent; then
			echo "k3s-agent"
		else
			echo "k3s"
		fi
	else
		echo "$runtime" | awk -F '[:]' '{print $1}'
	fi
}

function install_artifacts() {
	echo "copying kata artifacts onto host"
	cp -au /opt/kata-artifacts/opt/kata/* /opt/kata/
	chmod +x /opt/kata/bin/*
	[ -d /opt/kata/runtime-rs/bin ] && \
		chmod +x /opt/kata/runtime-rs/bin/*

	# Allow enabling debug for Kata Containers
	if [[ "${DEBUG:-"no"}" == "yes" ]]; then
		config_path="/opt/kata/share/defaults/kata-containers/"
		for shim in "${shims[@]}"; do
			sed -i -e 's/^#\(enable_debug\).*=.*$/\1 = true/g' "${config_path}/configuration-${shim}.toml"
			sed -i -e 's/^#\(debug_console_enabled\).*=.*$/\1 = true/g' "${config_path}/configuration-${shim}.toml"
			sed -i -e 's/^kernel_params = "\(.*\)"/kernel_params = "\1 agent.log=debug initcall_debug"/g' "${config_path}/configuration-${shim}.toml"
		done
	fi

	# Allow Mariner to use custom configuration.
	if [ "${HOST_OS:-}" == "cbl-mariner" ]; then
		config_path="/opt/kata/share/defaults/kata-containers/configuration-clh.toml"
		clh_path="/opt/kata/bin/cloud-hypervisor-glibc"
		sed -i -E 's|(enable_annotations) = .+|\1 = ["enable_iommu", "initrd", "kernel"]|' "${config_path}"
		sed -i -E "s|(valid_hypervisor_paths) = .+|\1 = [\"${clh_path}\"]|" "${config_path}"
		sed -i -E "s|(path) = \".+/cloud-hypervisor\"|\1 = \"${clh_path}\"|" "${config_path}"
	fi
}

function wait_till_node_is_ready() {
	local ready="False"

	while ! [[ "${ready}" == "True" ]]; do
		sleep 2s
		ready=$(kubectl get node $NODE_NAME -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
	done
}

function configure_cri_runtime() {
	configure_different_shims_base

	case $1 in
	crio)
		configure_crio
		;;
	containerd | k3s | k3s-agent | rke2-agent | rke2-server)
		configure_containerd
		;;
	esac
	systemctl daemon-reload
	systemctl restart "$1"

	wait_till_node_is_ready
}

function backup_shim() {
	local shim_file="$1"
	local shim_backup="${shim_file}.bak"

	if [ -f "${shim_file}" ]; then
		echo "warning: ${shim_file} already exists" >&2
		if [ ! -f "${shim_backup}" ]; then
			mv "${shim_file}" "${shim_backup}"
		else
			rm "${shim_file}"
		fi
	fi
}

function configure_different_shims_base() {
	# Currently containerd has an assumption on the location of the shimv2 implementation
	# This forces kata-deploy to create files in a well-defined location that's part of
	# the PATH, pointing to the containerd-shim-kata-v2 binary in /opt/kata/bin
	# Issues:
	#   https://github.com/containerd/containerd/issues/3073
	#   https://github.com/containerd/containerd/issues/5006

	local default_shim_file="/usr/local/bin/containerd-shim-kata-v2"

	mkdir -p /usr/local/bin

	for shim in "${shims[@]}"; do
		local shim_binary="containerd-shim-kata-${shim}-v2"
		local shim_file="/usr/local/bin/${shim_binary}"

		backup_shim "${shim_file}"

		if [[ "${shim}" == "dragonball" ]]; then
			ln -sf /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 "${shim_file}"
		else
			ln -sf /opt/kata/bin/containerd-shim-kata-v2 "${shim_file}"
		fi
		chmod +x "$shim_file"

		if [ "${shim}" == "${default_shim}" ]; then
			backup_shim "${default_shim_file}"

			echo "Creating the default shim-v2 binary"
			ln -sf "${shim_file}" "${default_shim_file}"
		fi
	done
}

function restore_shim() {
	local shim_file="$1"
	local shim_backup="${shim_file}.bak"

	if [ -f "${shim_backup}" ]; then
		mv "$shim_backup" "$shim_file"
	fi
}

function cleanup_different_shims_base() {
	local default_shim_file="/usr/local/bin/containerd-shim-kata-v2"

	for shim in "${shims[@]}"; do
		local shim_binary="containerd-shim-kata-${shim}-v2"
		local shim_file="/usr/local/bin/${shim_binary}"

		rm "${shim_file}" || true

		restore_shim "${shim_file}"
	done

	rm "${default_shim_file}" || true
	restore_shim "${default_shim_file}"
}

function configure_crio_runtime() {
	local runtime="kata"
	local configuration="configuration"
	if [ -n "${1-}" ]; then
		runtime+="-$1"
		configuration+="-$1"
	fi

	local kata_path="/usr/local/bin/containerd-shim-${runtime}-v2"
	local kata_conf="crio.runtime.runtimes.${runtime}"
	local kata_config_path="/opt/kata/share/defaults/kata-containers/$configuration.toml"

	cat <<EOF | tee -a "$crio_drop_in_conf_file"

# Path to the Kata Containers runtime binary that uses the $1
[$kata_conf]
	runtime_path = "${kata_path}"
	runtime_type = "vm"
	runtime_root = "/run/vc"
	runtime_config_path = "${kata_config_path}"
	privileged_without_host_devices = true
EOF
}

function configure_crio() {
	# Configure crio to use Kata:
	echo "Add Kata Containers as a supported runtime for CRIO:"

	# As we don't touch the original configuration file in any way,
	# let's just ensure we remove any exist configuration from a
	# previous deployment.
	mkdir -p "$crio_drop_in_conf_dir"
	rm -f "$crio_drop_in_conf_file"
	touch "$crio_drop_in_conf_file"

	for shim in "${shims[@]}"; do
		configure_crio_runtime $shim
	done


	if [ "${DEBUG:-"no"}" == "yes" ]; then
		cat <<EOF | tee -a $crio_drop_in_conf_file_debug
[crio]
log_level = "debug"
EOF
	fi
}

function configure_containerd_runtime() {
	local runtime="kata"
	local configuration="configuration"
	if [ -n "${1-}" ]; then
		runtime+="-$1"
		configuration+="-$1"
	fi
	local pluginid=cri
	if grep -q "version = 2\>" $containerd_conf_file; then
		pluginid=\"io.containerd.grpc.v1.cri\"
	fi
	local runtime_table="plugins.${pluginid}.containerd.runtimes.$runtime"
	local runtime_type="io.containerd.$runtime.v2"
	local options_table="$runtime_table.options"
	local config_path="/opt/kata/share/defaults/kata-containers/$configuration.toml"
	if grep -q "\[$runtime_table\]" $containerd_conf_file; then
		echo "Configuration exists for $runtime_table, overwriting"
		sed -i "/\[$runtime_table\]/,+1s#runtime_type.*#runtime_type = \"${runtime_type}\"#" $containerd_conf_file
	else
		cat <<EOF | tee -a "$containerd_conf_file"
[$runtime_table]
  runtime_type = "${runtime_type}"
  privileged_without_host_devices = true
  pod_annotations = ["io.katacontainers.*"]
EOF
	fi

	if grep -q "\[$options_table\]" $containerd_conf_file; then
		echo "Configuration exists for $options_table, overwriting"
		sed -i "/\[$options_table\]/,+1s#ConfigPath.*#ConfigPath = \"${config_path}\"#" $containerd_conf_file
	else
		cat <<EOF | tee -a "$containerd_conf_file"
  [$options_table]
    ConfigPath = "${config_path}"
EOF
	fi

	if [ "${DEBUG:-"no"}" == "yes" ]; then
		if grep -q "\[debug\]" $containerd_conf_file; then
			sed -i 's/level.*/level = \"debug\"/' $containerd_conf_file
		else
			cat <<EOF | tee -a "$containerd_conf_file"
[debug]
  level = "debug"
EOF
		fi

	fi
}

function configure_containerd() {
	# Configure containerd to use Kata:
	echo "Add Kata Containers as a supported runtime for containerd"

	mkdir -p /etc/containerd/

	if [ -f "$containerd_conf_file" ]; then
		# backup the config.toml only if a backup doesn't already exist (don't override original)
		cp -n "$containerd_conf_file" "$containerd_conf_file_backup"
	fi

	# Add default Kata runtime configuration
	configure_containerd_runtime

	for shim in "${shims[@]}"; do
		configure_containerd_runtime $shim
	done
}

function remove_artifacts() {
	echo "deleting kata artifacts"
	rm -rf /opt/kata/
}

function cleanup_cri_runtime() {
	cleanup_different_shims_base

	case $1 in
	crio)
		cleanup_crio
		;;
	containerd | k3s | k3s-agent | rke2-agent | rke2-server)
		cleanup_containerd
		;;
	esac

}

function cleanup_crio() {
	rm $crio_drop_in_conf_file
	if [[ "${DEBUG:-"no"}" == "yes" ]]; then
		rm $crio_drop_in_conf_file_debug
	fi
}

function cleanup_containerd() {
	rm -f $containerd_conf_file
	if [ -f "$containerd_conf_file_backup" ]; then
		mv "$containerd_conf_file_backup" "$containerd_conf_file"
	fi
}

function reset_runtime() {
	kubectl label node "$NODE_NAME" katacontainers.io/kata-runtime-
	systemctl daemon-reload
	systemctl restart "$1"
	if [ "$1" == "crio" ] || [ "$1" == "containerd" ]; then
		systemctl restart kubelet
	fi

	wait_till_node_is_ready
}

function main() {
	# script requires that user is root
	euid=$(id -u)
	if [[ $euid -ne 0 ]]; then
	   die  "This script must be run as root"
	fi

	runtime=$(get_container_runtime)

	# CRI-O isn't consistent with the naming -- let's use crio to match the service file
	if [ "$runtime" == "cri-o" ]; then
		runtime="crio"
	elif [ "$runtime" == "k3s" ] || [ "$runtime" == "k3s-agent" ] || [ "$runtime" == "rke2-agent" ] || [ "$runtime" == "rke2-server" ]; then
		containerd_conf_tmpl_file="${containerd_conf_file}.tmpl"
		if [ ! -f "$containerd_conf_tmpl_file" ]; then
			cp "$containerd_conf_file" "$containerd_conf_tmpl_file"
		fi

		containerd_conf_file="${containerd_conf_tmpl_file}"
		containerd_conf_file_backup="${containerd_conf_file}.bak"
	else
		# runtime == containerd
		if [ ! -f "$containerd_conf_file" ] && [ -d $(dirname "$containerd_conf_file") ] && \
			[ -x $(command -v containerd) ]; then
			containerd config default > "$containerd_conf_file"
		fi
	fi

	action=${1:-}
	if [ -z "$action" ]; then
		print_usage
		die "invalid arguments"
	fi

	# only install / remove / update if we are dealing with CRIO or containerd
	if [[ "$runtime" =~ ^(crio|containerd|k3s|k3s-agent|rke2-agent|rke2-server)$ ]]; then

		case "$action" in
		install)
			install_artifacts
			configure_cri_runtime "$runtime"
			kubectl label node "$NODE_NAME" --overwrite katacontainers.io/kata-runtime=true
			;;
		cleanup)
			cleanup_cri_runtime "$runtime"
			kubectl label node "$NODE_NAME" --overwrite katacontainers.io/kata-runtime=cleanup
			remove_artifacts
			;;
		reset)
			reset_runtime $runtime
			;;
		*)
			echo invalid arguments
			print_usage
			;;
		esac
	fi

	#It is assumed this script will be called as a daemonset. As a result, do
        # not return, otherwise the daemon will restart and rexecute the script
	sleep infinity
}

main "$@"
