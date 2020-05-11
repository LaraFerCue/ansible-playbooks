#!/bin/sh

: "${ZPOOL:=zroot}"
: "${BASEDIR:=/usr/jails}"
: "${TARBALLS_DIR:=${BASEDIR}/tarballs}"
: "${EXTRA_TARBALLS:=}"
: "${FTP_URL:=ftp://ftp.freebsd.org/pub/FreeBSD}"

TARBALLS="base.txz lib32.txz"

NAME=${1}
VERSION=${2}
PROG=$(basename "${0}")

SRCDIR=$(dirname "${PROG}")

usage() {
	cat << USAGE
${PROG} <name> <version>

	name: The name of the jail as defined in jail(8)
	version: The version of FreeBSD to use in the jail
USAGE
}

check_version() {
	local version=${1}
	local version_number version_type
	local system_version

	version_number=$(echo "${version}" | \
		sed 's/^\([0-9]*\)\.\([0-9]*\).*/\1\2/')
	system_version=$(uname -r | \
		sed 's/^\([0-9]*\)\.\([0-9]*\).*/\1\2/')

	[ "${version_number}" -le "${system_version}" ]
}

fetch_tarballs() {
	local version="${1}"
	local arch

	arch="$(uname -m)"
	mkdir -p "${TARBALLS_DIR}/${version}"
	if echo "${version}" | grep -q 'RELEASE' ; then
		FTP_URL="${FTP_URL}/releases"
	else
		FTP_URL="${FTP_URL}/snapshots"
	fi
	
	for tarball in ${TARBALLS} ${EXTRA_TARBALLS}; do
		if [ -r "${TARBALLS_DIR}/${version}/${tarball}" ] ; then
			continue
		fi
		ftp -o "${TARBALLS_DIR}/${version}/${tarball}" \
			"${FTP_URL}/${arch}/${arch}/${version}/${tarball}"
	done
}

create_base_jail() {
	local version=${1}

	zfs create "${ZPOOL}${BASEDIR}/${version}"
	for tarball in ${TARBALLS} ${EXTRA_TARBALLS} ; do
		tar -xf "${TARBALLS_DIR}/${version}/${tarball}" \
			-C "${BASEDIR}/${version}"
	done
	sysrc -f "${BASEDIR}/${version}/etc/rc.conf" \
		sendmail_enable=NONE

	env PAGER=cat freebsd-update --currently-running "${version}" \
		-b "${BASEDIR}/${version}" fetch
	freebsd-update -b "${BASEDIR}/${version}" install || true
	cp -a /etc/resolv.conf "${BASEDIR}/${version}/etc/resolv.conf"
	zfs snapshot "${ZPOOL}${BASEDIR}/${version}@base_jail"
}

create_jail() {
	local version=${1}
	local name=${2}

	zfs clone "${ZPOOL}${BASEDIR}/${version}@base_jail" \
		"${ZPOOL}${BASEDIR}/${name}"
	if ! [ -r /etc/jail.conf ] ; then
		cp -a "${SRCDIR}/jail.conf" /etc/jail.conf
		echo "\$basedir = \"${BASEDIR}\";" >> /etc/jail.conf
	fi

	if ! grep -qE "^ifconfig_jailsnat" /etc/rc.conf ; then
		local bridge_number=$(ifconfig -g bridge | wc -w | tr -d '[:space:]')
		sysrc cloned_interfaces+="bridge${bridge_number}"
		sysrc "ifconfig_bridge${bridge_number}_name"="jailsnat"
		sysrc ifconfig_jailsnat="inet 1.0.0.1/24"
	fi
	cat >> /etc/jail.conf << JAIL_CONF
${name} {
	osrelease = "${version}";

	vnet.interface = "${name}1";
}
JAIL_CONF
	
	local vnet_number=$(ifconfig -g epair | wc -w)
	: $(( vnet_number /= 2))
	if ! grep -qE "_name=\"${name}0\"" /etc/rc.conf ; then
		sysrc cloned_interfaces+="epair${vnet_number}"
		sysrc "ifconfig_epair${vnet_number}a_name=${name}0"
		sysrc "ifconfig_epair${vnet_number}b_name=${name}1"

		sysrc ifconfig_jailsnat+="addm ${name}0"
	fi

	sysrc -f "${BASEDIR}/${name}/etc/rc.conf" \
		"ifconfig_${name}1"="inet 1.0.0.1${vnet_number}/24"
	sysrc -f "${BASEDIR}/${name}/etc/rc.conf" \
		defaultrouter="1.0.0.1"
	sysrc -f "${BASEDIR}/${name}/etc/rc.conf" \
		sshd_enable=YES
	chroot "${BASEDIR}/${name}" pw useradd ansible -G wheel,operator \
		-s /bin/tcsh -h 0 -m

	local port=$(printf "22%02d" ${vnet_number})

	configure_pf
	awk -v port="${port}" -v ip="1.0.0.1${vnet_number}" '/^pass/ { 
		printf "rdr on $ext_if proto tcp from any to any port %d -> %s port 22\n", port, ip;
	}
	{
		print $0;
	}' /etc/pf.conf > /tmp/pf.conf
	mv /tmp/pf.conf /etc/pf.conf
}

configure_pf() {
	if ! [ -r /etc/pf.conf ] ; then
		cp -a "${SRCDIR}/pf.conf" /etc/pf.conf
		sysrc pf_enable="YES"
	fi
}

if [ -z "${NAME}" ] || [ -z "${VERSION}" ] ; then
	usage
	exit 1
fi

if ! check_version "${VERSION}" ; then
	cat << VERSION_ERROR
WARNING: The version of FreeBSD is greater than the running system.
	 Refusing to continue.
VERSION_ERROR
	exit 2
fi

if ! zfs list "${ZPOOL}${BASEDIR}" > /dev/null 2> /dev/null ; then
	zfs create "${ZPOOL}${BASEDIR}"
fi

fetch_tarballs "${VERSION}"

if ! zfs list "${ZPOOL}${BASEDIR}/${VERSION}" > /dev/null 2> /dev/null ; then
	create_base_jail "${VERSION}"
fi

create_jail "${VERSION}" "${NAME}"

if ! grep -qE 'net.inet.ip.forwarding=1' /etc/sysctl.conf ; then
	echo 'net.inet.ip.forwarding=1' >> /etc/sysctl.conf
fi
