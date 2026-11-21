# Team access: accounts, keys, VPN

How the four of us get into the cluster, and what keeps everyone else out.
Settings live in [`config/team.conf`](../config/team.conf).

## What the cluster looks like from a laptop

| Name | Server | How you reach it |
|---|---|---|
| `head` / `3ncryp3d-head` | node3: NFS, NAT, venue uplink | VPN (`10.99.0.1`), or `head-direct` as backup |
| `c1` / `3ncryp3d-c1` | node1 | through the head (ProxyJump) |
| `c2` / `3ncryp3d-c2` | node2 | through the head (ProxyJump) |

The old names `node1`, `node2`, `node3` still work on the cluster.

## The layers

1. **VPN (WireGuard, on the head).** Laptop to head only, and it doesn't
   need the venue's internet. Only the head's VPN address goes through the
   tunnel, so your normal internet is untouched. Cluster traffic (MPI, NFS)
   never uses it.
2. **SSH, keys only.** Password login is off, root login is off, and only
   `saxs swaetc ole rendi` (plus `ubuntu` for emergencies) may log in. Each
   person's laptop key is accepted only for their own account.
3. **Backup way in (`SSH_ON_UPLINK=yes`).** SSH also answers on the venue
   port, keys only, so a broken VPN doesn't stop a submission. fail2ban bans
   an address after 5 failed attempts in 10 minutes. Set
   `SSH_ON_UPLINK=no` once the VPN has proved itself.
4. **The cluster's identity is known in advance.** Each node's SSH host key
   is made before install and given to the laptops, so SSH refuses to
   connect if anything else answers as `head` on the shared venue network.
5. **Internal keys work only on the cables.** Each user has an internal key
   for node-to-node SSH and MPI. The nodes accept it only from 10.0.x.x
   (the direct cables), so a copied internal key or install stick is useless
   from the venue network.
6. **Emergency:** iLO's remote console, logging in as `ubuntu` with its
   install password. sshd's settings don't affect the console.

Inside the cluster everyone has the same uid on every node, is in the
`team` group, and has sudo with no password (`SUDO_NOPASSWD=yes`; the
reasoning is in team.conf). Shared work goes in `/mnt/shared/runs`
(group-writable, so anyone can rerun or submit anyone's run). Home
folders stay on each node's own disk, so logins still work if NFS is down.

## What each person does, once, before we leave

On your Windows laptop (OpenSSH is built into Windows 10/11):

1. Install WireGuard for Windows from <https://www.wireguard.com/install/>.
2. In PowerShell, from the repo folder:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\laptop\setup-laptop.ps1 -Init -User ole
   ```

   Pick a passphrase. Send the `3ncryp3d-keys-ole` folder on your Desktop to
   the captain, and read your fingerprint's last 6 characters to them on a
   call.
3. Once, in an **admin** PowerShell, so you type the passphrase only once
   per Windows login:

   ```powershell
   Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent
   ssh-add $HOME\.ssh\id_ed25519_3ncryp3d
   ```

4. When the captain says the keys are built (`git pull`):

   ```powershell
   .\laptop\setup-laptop.ps1 -Configure -User ole
   ```

   Then WireGuard > Import tunnel(s) from file >
   `C:\Users\<you>\.3ncryp3d\3ncryp3d.conf`. (Run the script as admin and it
   installs the tunnel for you.)

## On the day

- If `3ncryp3d-head.local` doesn't resolve on the venue network, read the
  head's IP off its screen or iLO and run
  `.\laptop\setup-laptop.ps1 -Configure -User ole -HeadAddress <IP>`.
- Activate the `3ncryp3d` tunnel in WireGuard, then `ssh head`, `ssh c1`, `ssh c2`.
- VPN broken? `ssh head-direct`, and `ssh -J head-direct c1` for the computes.
- `.\laptop\setup-laptop.ps1 -Check` tests all three.

## Lost or stolen laptop

Tell the captain at once. On the head, as any other team member:

```bash
sudo team-key revoke ole     # removes ole's laptop key on all 3 nodes + her VPN access
```

Her account, files and internal key stay. She makes a new pair with
`-Init` on another laptop, and you allow it with
`sudo team-key add ole ole.pub`. For the VPN: put her new `.wg.pub` in
`/etc/cluster/team/keys/wg/ole.pub` on the head and run
`sudo /etc/cluster/team/bin/team-setup.sh`.

## For the captain: building the keys

See [`keys/README.md`](../keys/README.md). In short: collect the public
keys into `keys/`, run `tools/make-team-secrets.sh`, commit `keys/`. Then:

- **OpenStack test cluster:** `create_cluster.sh` does the rest
  (`TEAM_ACCOUNTS=yes` is the default). The VPN needs UDP 51820 open in
  node3's security group, which the script doesn't add.
- **Real servers:** `sudo baremetal/install.sh nodeN.env state/team`.
- **The install stick (Phase 1)** will carry the same bundle.

## Tested (2026-11-21, Ubuntu 24.04)

On a stand-in head node with a real sshd and fake laptop keys, all of these
behaved as intended:

- laptop key logs in; someone else's key is refused
- internal key works from 127.0.0.1 and is refused from a non-cable address
- root, password login and unknown users are refused
- sudo works with no password
- `team-key revoke` and `add` work
- a laptop configured by `setup-laptop.ps1` logs in, and refuses a server
  with the wrong host key
- the firewall loads twice without touching fail2ban's table
- the OpenStack dry-run (scenarios 1-9) still passes

**Not yet tested:** the PowerShell script on real Windows (only checked
under PowerShell 7 on Linux), WireGuard and fail2ban actually running (the
test box has no systemd), and team-key reaching the other two nodes over
the cables. All three need a real or OpenStack cluster.
