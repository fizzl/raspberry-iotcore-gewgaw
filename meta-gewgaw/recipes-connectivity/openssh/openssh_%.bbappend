# Force service mode so sshd is started as a daemon on boot under systemd.
PACKAGECONFIG:remove = "systemd-sshd-socket-mode"
PACKAGECONFIG:append = " systemd-sshd-service-mode"
SYSTEMD_AUTO_ENABLE:${PN}-sshd = "enable"
