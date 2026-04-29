SUMMARY = "Preinstall the gewgaw target-root SSH public key for the root account"
DESCRIPTION = "Installs target-root.pem.pub (generated on the host by setup.sh) as \
/home/root/.ssh/authorized_keys and drops a small sshd_config.d snippet that \
requires public-key auth for root."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://target-root.pem.pub \
    file://10-gewgaw.conf \
"

S = "${WORKDIR}"

do_compile[noexec] = "1"
do_configure[noexec] = "1"

FILES:${PN} = " \
    /home/root/.ssh/authorized_keys \
    ${sysconfdir}/ssh/sshd_config.d/10-gewgaw.conf \
"

RDEPENDS:${PN} = "openssh-sshd"

do_install() {
    install -d -m 0700 ${D}/home/root/.ssh
    install -m 0600 ${WORKDIR}/target-root.pem.pub \
        ${D}/home/root/.ssh/authorized_keys

    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    install -m 0644 ${WORKDIR}/10-gewgaw.conf \
        ${D}${sysconfdir}/ssh/sshd_config.d/10-gewgaw.conf
}
