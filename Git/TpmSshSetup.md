# TPM-Backed SSH Access to a Git Repository

Set up TPM2-backed SSH authentication for a git repository.
The private key is non-exportable — it never leaves the TPM hardware.
Works with any SSH-accessible git server; per-repo scoping depends on the server
(GitHub deploy keys, GitLab deploy tokens, Gitea deploy keys, or `authorized_keys` on self-hosted).

## Host Setup

### NixOS Host

```nix
security.tpm2 = {
    enable = true;       # udev rules for /dev/tpm* (root:tss 0660), loads kernel module
    pkcs11.enable = true; # libtpm2_pkcs11.so and tpm2_ptool on system path
    tctiEnvironment.enable = true; # sets TPM2TOOLS_TCTI and TPM2_PKCS11_TCTI to device:/dev/tpmrm0
};

users.users."<username>".extraGroups = [ "tss" ];
```

Optionally suppress FAPI backend probe warnings (cosmetic, see Notes):

```nix
environment.sessionVariables.TSS2_LOG = "fapi+NONE";
```

### NixOS Container (bind-mounted TPM from host)

Containers see the host's `/dev/tpmrm0` via bind mount, but udev rules don't fire
for bind-mounted devices, and host/container GID namespaces differ. Requires setup
in two places:

**In the host config** — bind-mount TPM devices into the container:

```nix
containers.<name>.bindMounts."/dev/tpm0"    = { hostPath = "/dev/tpm0";    isReadOnly = false; };
containers.<name>.bindMounts."/dev/tpmrm0"  = { hostPath = "/dev/tpmrm0"; isReadOnly = false; };
```

**Inside the container's own config** — all of the following:

```nix
security.tpm2 = {
    # enable: creates tss user/group and installs udev rules.
    # Kernel module loading is a no-op in containers (already loaded by host).
    # Needed because tss group creation is gated on this flag;
    # pkcs11/tctiEnvironment alone don't create the group.
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
};

users.users."<username>".extraGroups = [ "tss" ];

environment.sessionVariables.TSS2_LOG = "fapi+NONE";

# Fix device ownership on boot — the host's tss GID differs from the container's
# because they allocate system GIDs independently
systemd.services.tpm-device-permissions = {
    description = "Set TPM device permissions for container use";
    wantedBy = [ "multi-user.target" ];
    # Must run after groups are created — chgrp tss fails
    # if the tss group doesn't exist yet
    after = [ "systemd-sysusers.service" ];
    serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "tpm-device-permissions" ''
            set -euo pipefail
            chgrp tss /dev/tpm0 /dev/tpmrm0
            chmod 660 /dev/tpm0 /dev/tpmrm0
        '';
    };
};
```

### Windows

Windows TPM access for SSH is possible but has unresolved friction.
Known approaches:

**Virtual Smart Card + OpenSC PKCS#11**:
`tpmvscmgr.exe create` creates a TPM-backed virtual smart card.
OpenSC's `opensc-pkcs11.dll` exposes it as a PKCS#11 provider.
Issues: Microsoft is deprecating `tpmvscmgr` in favor of Windows Hello.
Also, Git-for-Windows bundles MSYS2 OpenSSH which crashes (AV) when loading
OpenSC's native PKCS#11 DLL — likely a calling convention (`CK_CALL_SPEC`)
mismatch. Needs debugging with CDB.

Using Windows native OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe` via
`GIT_SSH_COMMAND`) avoids the MSYS2 issue. Caveats:
- Versions before 9.2.2.0 have a race condition (#1322/#2012) where server
  responses are truncated (`fatal: early EOF` during git fetch/clone) —
  `CancelIoEx()` aborts in-flight writes before data is fully read.
  Fixed in v9.2.2.0p1-Beta; inbox fix from Windows 11 24H2 (ships 9.5p1).
- Upstream OpenSSH 10.1/10.2 have a PIN entry regression, fixed in 10.3.
- ssh-agent stores smartcard PINs in the registry in plaintext (#2341,
  open as of Mar 2025).
- Install latest from GitHub for best results:
  `winget install "openssh preview"` (10.0.0.0p2-Preview as of Oct 2025).

**ncrypt-pkcs11** (third-party):
Wraps Windows CNG/NCrypt directly as PKCS#11, bypassing the smart card layer.
Keys created with `Microsoft Platform Crypto Provider` are TPM-backed.
Less mature than OpenSC. May or may not have the same MSYS2 ABI issue —
depends on whether it defines `CK_CALL_SPEC` the same way. Quick test:
swap the DLL path in `PKCS11Provider` and see if it crashes.

**FIDO2 / `ecdsa-sk`**:
`ssh-keygen -t ecdsa-sk` with Windows Hello as the FIDO2 authenticator.
No PKCS#11 involved — OpenSSH talks FIDO2 natively.
Simplest setup, but produces a different key type than the Linux PKCS#11 path.

### Verification

After setup, as the target user:

```bash
tpm2_ptool init              # create primary (first time only)
tpm2_ptool listtokens --pid=1  # should return empty list, no errors
```

## Per-Repository Setup

### 1. Decide on token and key naming

PKCS#11 has two levels: tokens (groups of keys) and keys (within a token).
Group keys by service, name keys by repo:

- Token: `github` (one token for all GitHub repos)
- Key label: exact repo name, e.g., `HyperNix`

You can mix: multiple tokens, multiple keys per token, single-key tokens.

If the token doesn't exist yet:

```bash
tpm2_ptool addtoken --pid=1 --label=github --sopin=<so-pin> --userpin=<user-pin>
```

### 2. Create the key

```bash
tpm2_ptool addkey --label=github --userpin=<user-pin> --algorithm=ecc256 --key-label=<repo-name>
```

Verify:

```bash
tpm2_ptool listobjects --label=github
```

Should show the key with `CKA_LABEL: <repo-name>`.

### 3. Extract the public key

```bash
ssh-keygen -D /run/current-system/sw/lib/libtpm2_pkcs11.so
```

Prints one line per key. The key label appears at the end of the line.

Save the key for this repo to a `.pub` file (used by SSH config to select
which PKCS#11 key to offer — see step 5):

```bash
ssh-keygen -D /run/current-system/sw/lib/libtpm2_pkcs11.so \
  | grep <repo-name> > ~/.ssh/tpm.<service>.<repo-name>.pub
```

For example: `~/.ssh/tpm.github.HyperNix.pub`

### 4. Enroll the public key on the server

Register the public key from step 3 on the git server.
How this works depends on the server:

**GitHub** — deploy key (per-repo):
`https://github.com/<owner>/<repo>/settings/keys` → "Add deploy key"
Check "Allow write access" if push is needed.

**GitLab** — deploy key (per-repo):
`https://gitlab.com/<owner>/<repo>/-/settings/repository` → Deploy keys

**Self-hosted / generic SSH**:
Add the public key to `~/.ssh/authorized_keys` on the server,
optionally restricted with `command=` or `restrict` options.

CLI shortcut for GitHub (requires `gh` authenticated):

```bash
ssh-keygen -D /run/current-system/sw/lib/libtpm2_pkcs11.so \
  | grep <repo-name> \
  | gh repo deploy-key add - --repo <owner>/<repo> --title "TPM2 - $(hostname)" -w
```

### 5. SSH config

Add a host alias in `~/.ssh/config`:

```
Host <service>.<repo-name>
    HostName github.com
    User git
    PKCS11Provider /run/current-system/sw/lib/libtpm2_pkcs11.so
    IdentityFile ~/.ssh/tpm.<service>.<repo-name>.pub
    IdentitiesOnly yes
```

For example: `Host github.HyperNix`

`IdentityFile` points to the `.pub` file from step 3. SSH loads all keys from
the PKCS#11 provider, matches them against this public key, and offers only the
matching one. `IdentitiesOnly yes` ensures no other keys are tried.
This keeps the server happy when you have many keys (GitHub cuts off after 5 attempts).

### 6. Clone or add remote

```bash
git clone git@<service>.<repo-name>:<owner>/<repo>.git

# Or add to existing repo:
git remote add github git@<service>.<repo-name>:<owner>/<repo>.git
```

For example: `git clone git@github.HyperNix:hypersw/HyperNix.git`

### 7. Test

```bash
ssh git@<service>.<repo-name>
```

Expected: `Hi <owner>/<repo>! You've successfully authenticated, but GitHub does not provide shell access.`

If prompted for a PIN, see next section.

## PIN Handling

PKCS#11 requires a PIN to access keys. The real security is the TPM hardware +
optional PCR policy — the PIN is a PKCS#11 formality. Three approaches:

### Option A: Trivial constant PIN with silent bypass

Use the same trivial PIN everywhere, hardcode it in an askpass script:

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/pkcs11-askpass << 'SCRIPT'
#!/bin/sh
echo <user-pin>
SCRIPT
chmod +x ~/.local/bin/pkcs11-askpass
```

Set globally (e.g., in shell profile or NixOS `sessionVariables`):

```bash
export SSH_ASKPASS=~/.local/bin/pkcs11-askpass
export SSH_ASKPASS_REQUIRE=force
```

No prompts ever. PIN is on disk in the script.

### Option B: Cached with timeout (recommended)

Prompted on first use, cached in memory for 1 hour via `git credential-cache`.
Only handles PKCS#11 PIN prompts — other SSH prompts (passphrases, passwords)
fall through to the terminal.

A ready-made helper is available as a flake in this repo:

```
Git/SshAskpassCredentialHelper/
```

**NixOS module** (if the flake is added as an input):

```nix
programs.ssh-askpass-credential-helper.enable = true;
```

This sets `SSH_ASKPASS` and `SSH_ASKPASS_REQUIRE` automatically.

**Standalone use**:

```bash
nix run path:Git/SshAskpassCredentialHelper
# or
nix shell path:Git/SshAskpassCredentialHelper
export SSH_ASKPASS=$(which ssh-askpass-credential-helper)
export SSH_ASKPASS_REQUIRE=prefer
```

The helper uses the full SSH prompt string as the cache key, so different
tokens get independent cache entries automatically. Works with one shared PIN
or unique PINs per token — no configuration needed.

### Option C: Unique PINs per token

Same helper as Option B — it already works with multiple tokens because
SSH passes a different prompt per token (e.g., `Enter PIN for 'github':` vs
`Enter PIN for 'gitlab':`). Each prompt is a separate cache key.

## Rekeying (new machine or container)

Each machine/container creates its own key. To add a new machine:

1. Repeat the per-repository steps on the new machine
2. Add the new public key as another deploy key on the same repo
3. Old machines keep working — multiple deploy keys coexist

To revoke a machine: delete its deploy key from the repo settings.

## Notes

- Per-repo scoping depends on the server. GitHub/GitLab deploy keys are single-repo.
  On self-hosted servers, scoping is up to your `authorized_keys` / access control config.
- The TPM-wrapped key blob lives in `$TPM2_PKCS11_STORE/tpm2_pkcs11.sqlite3`.
  It's encrypted under this TPM's SRK — useless on any other machine.
- `TSS2_LOG=fapi+NONE` suppresses harmless FAPI probe warnings.
  The library always probes both ESAPI and FAPI backends; we only use ESAPI.
  Disabling the probe entirely requires recompiling `tpm2-pkcs11` with `--with-fapi=no`.
