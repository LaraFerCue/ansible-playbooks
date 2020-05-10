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

	cat >> /etc/jail.conf << JAIL_CONF
${name} {
	osrelease = "${version}";
}
JAIL_CONF
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
