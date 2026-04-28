# Replace any alternative SSH server and install OpenSSH in a standard image-feature way.
IMAGE_FEATURES:remove = "ssh-server-dropbear"
IMAGE_FEATURES += "ssh-server-openssh"

# Install a tiny package that places root's authorized_keys into the image.
IMAGE_INSTALL:append = " root-authorized-key"
