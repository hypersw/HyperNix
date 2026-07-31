# Secure rclone configuration and mounts

`hypersw.programs.rcloneSecureConfig` is manifestation-neutral: it works in a
container, VM, or physical NixOS installation. It owns all common rclone mount
service policy. Consumers only declare the remotes they want and their mount
points.

All configured mounts for one module instance share one encrypted
`rclone.conf`, and therefore one TPM-bound configuration-password credential.
The remotes inside that config carry distinct OAuth tokens. Separate FUSE
services are necessary because each mountpoint needs its own long-running
rclone process; they do not imply duplicated configs or credentials.

```nix
hypersw.programs.rcloneSecureConfig = {
  enable = true;
  user = "webAgent";
  mounts = {
    onedrive.mountPoint = "/home/webAgent/OneDrive";
    gdrive.mountPoint = "/home/webAgent/GoogleDrive";
  };
};
```

This creates `rclone-mount-onedrive.service` and
`rclone-mount-gdrive.service` in that user's systemd manager. Both use the
same encrypted config and credential; `onedrive` and `gdrive` are the remote
names to create during initial authorization.

## First authorization

The module's bootstrap user service generates a random configuration password
only when both the password credential and `rclone.conf` are absent. It streams
random data directly into `systemd-creds encrypt --user --with-key=tpm2`; no
plaintext password is written to disk. If a config exists but its credential is
lost, bootstrap refuses to generate a replacement, protecting against silent
loss of access to the encrypted config.

Run `rclone-secure-config` as the configured user. It starts the bootstrap
service, opens an interactive transient systemd service carrying the decrypted
password, and runs `rclone config` there. In rclone's menu, first enable config
encryption, then create the desired OAuth remotes. For later maintenance, run
the same command again rather than bare `rclone config`.

The guest must have TPM and FUSE access. In a systemd-nspawn container this
means exposing `/dev/tpm0`, `/dev/tpmrm0`, and `/dev/fuse` and allowing those
devices at the host/container boundary.
