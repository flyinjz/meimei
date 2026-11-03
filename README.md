# i2s

A music player. The source in this repository is encrypted. Commit history is public.

## Encryption

Every file except `README.md`, `.gitattributes`, `.gitignore`, `.crypt/`, `.git-crypt/` and `KEYS/` is encrypted with [git-crypt](https://github.com/AGWA/git-crypt) before it leaves the author's machine. The ciphertext is then base64-armored by [`.crypt/armor`](.crypt/armor), so on GitHub each file reads as a block of text between `BEGIN/END I2S ENCRYPTED FILE` markers.

- Cipher: AES-256-CTR with an HMAC-SHA1 synthetic IV, from git-crypt. The armor only changes the encoding. It adds no security and removes none.
- The symmetric key exists only on authorised machines. The copies in `.git-crypt/keys/` are wrapped to the authorised GPG keys.
- GitHub stores and serves ciphertext only. Without a key, a clone contains only the armored text.
- File names are random and meaningless; the real layout is kept off the repository.
- Visible in plaintext: the opaque file names, approximate file sizes, commit messages, authors and timestamps.
- Encryption is deterministic: identical plaintext gives identical ciphertext, so unchanged files can be spotted.

## Signing

Every commit and tag is signed by `xpgr`. Unsigned pushes to `main` are rejected by a repository rule.

```
xpgr <132859844+flyinjz@users.noreply.github.com>
ed25519  6A32 DA43 D0F1 8EE5 03FD  32CC F341 AFF9 2333 603A
```

The public key is in [`KEYS/xpgr.asc`](KEYS/xpgr.asc) and below. To verify:

```sh
gpg --import KEYS/xpgr.asc
git log --show-signature
git verify-commit HEAD
```

<details>
<summary>Public key</summary>

```
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEaujS7RYJKwYBBAHaRw8BAQdAeSllXxA9j7K5/mTuvhdbN50Q+vBP+YNQgieZ
XS+FrJK0MXhwZ3IgPDEzMjg1OTg0NCtmbHlpbmp6QHVzZXJzLm5vcmVwbHkuZ2l0
aHViLmNvbT6IrwQTFgoAVxYhBGoy2kPQ8Y7lA/0yzPNBr/kjM2A6BQJq6NLtGxSA
AAAAAAQADm1hbnUyLDIuNSsxLjEyLDAsMwIbAwULCQgHAgIiAgYVCgkICwIEFgID
AQIeBwIXgAAKCRDzQa/5IzNgOpOKAQCvdfuRgk6cxUGJHzKDru/9KqX8ELH+rbiz
Dv7xtCBXjwD/bLN+7Dv8+CrIA5qVePSkpORX1XF7NHoP7XFLkovIogy4OARq6NMH
EgorBgEEAZdVAQUBAQdAW8R56GrATARjkSdjB5fNvmxoV/fl3u2WBR371emkE3ED
AQgHiJQEGBYKADwWIQRqMtpD0PGO5QP9MszzQa/5IzNgOgUCaujTBxsUgAAAAAAE
AA5tYW51MiwyLjUrMS4xMiwwLDMCGwwACgkQ80Gv+SMzYDqU8QD+OHSuQ8RKTZDz
4wJPDCBKPFBVJFOLJumdf69GbM5tI/EBAJnISjdoSA45vkIcllWjvc/zfZVmUIIQ
bJ9U8lLNrSUO
=0Qfl
-----END PGP PUBLIC KEY BLOCK-----
```

</details>

## Access

To unlock a clone, you need git-crypt, OpenSSL and a GPG key that has been added as a collaborator:

```sh
.crypt/unlock
```
