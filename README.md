# i2s

A music player for macOS, with a Windows port in progress. Earlier commits (up to 2026-11-14) hold the source encrypted with git-crypt; from then on it is plain text.

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
