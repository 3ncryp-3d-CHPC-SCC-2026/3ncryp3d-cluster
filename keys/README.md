# keys/: the team's PUBLIC keys

Only public keys belong here, and they are safe to commit. Private keys
never leave their laptop.

| File | What it is | Who makes it |
|---|---|---|
| `ssh/<user>.pub` | the user's laptop SSH key (lets them log in) | `laptop\setup-laptop.ps1 -Init` on their laptop |
| `wg/<user>.pub` | the user's laptop WireGuard key (lets them use the VPN) | same (the file is called `<user>.wg.pub` on their Desktop) |
| `cluster-public.env` | the cluster's own identity keys and VPN settings, for the laptops | `tools/make-team-secrets.sh` |

`<user>` must match a name in `config/team.conf` (saxs, swaetc, ole, rendi).

## Adding a teammate's keys

1. They run `.\setup-laptop.ps1 -Init -User <user>` and send you the
   `3ncryp3d-keys-<user>` folder from their Desktop.
2. **Check the fingerprint on a call.** They read the last 6 characters of
   the line the script printed; you run `ssh-keygen -lf keys/ssh/<user>.pub`
   and compare. This proves nobody swapped the key on the way.
3. Copy the files in:

   ```bash
   cp <user>.pub    keys/ssh/<user>.pub
   cp <user>.wg.pub keys/wg/<user>.pub
   ```

4. Run `tools/make-team-secrets.sh` (Linux or WSL). It refuses any file that
   is really a private key. It then rewrites `keys/cluster-public.env`.
5. Commit `keys/`. The private half it made is in `state/team/`, which is
   git-ignored. Keep it that way: it goes on the install stick, nowhere else.

A laptop key added after the cluster is up: `sudo team-key add <user> FILE.pub`
on the head node. A lost laptop: `sudo team-key revoke <user>`.
