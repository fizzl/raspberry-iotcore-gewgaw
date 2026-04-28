SUMMARY = "Install root authorized_keys from the custom layer"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "file://authorized_keys"

S = "${WORKDIR}"

inherit allarch

do_install() {
    install -d -m 0700 ${D}/home/root/.ssh
    install -m 0600 ${WORKDIR}/authorized_keys ${D}/home/root/.ssh/authorized_keys
}

FILES:${PN} = "/home/root/.ssh /home/root/.ssh/authorized_keys"
CONFFILES:${PN} = "/home/root/.ssh/authorized_keys"
