SUMMARY = "Static IP configuration for eth0 (192.168.55.5/24) via systemd-networkd"
DESCRIPTION = "Drops a systemd-networkd .network unit so eth0 always comes up with \
the gewgaw project's wired LAN address."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://10-eth0-static.network"

S = "${WORKDIR}"

# Pure data recipe — nothing to compile or configure.
do_compile[noexec] = "1"
do_configure[noexec] = "1"

FILES:${PN} = "${sysconfdir}/systemd/network/10-eth0-static.network"

RDEPENDS:${PN} = "systemd"

do_install() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${WORKDIR}/10-eth0-static.network \
        ${D}${sysconfdir}/systemd/network/10-eth0-static.network
}
