# SWGRCouch signing certificate (public part)

`swgrcouch-cert.pem` is the **public** certificate the SWGRCouch author signs `swgr_inputfilter.dll` with, starting
with release 1.0.1. It holds no private key.

| | |
|---|---|
| Subject / issuer | `CN=Jules (SWGRCouch), O=SWGRCouch` (self-signed) |
| Serial | `541B05F586E72D3C317A7289D01E47A6F2803B8A` |
| Valid | 2026-10-20 to 2036-10-17 |
| Key | RSA 3072, Extended Key Usage: Code Signing |
| **SHA-256 fingerprint** | `05:FA:00:C4:E0:53:2B:0C:86:62:6A:2E:6B:1D:A6:C4:4C:62:55:97:5D:A7:2E:18:99:76:24:1A:C0:A8:1A:A7` |

This is a **local signature by the author, not a CA-trusted one**: no certificate authority vouches for it, so Windows
still shows *unknown publisher* (and SmartScreen may still warn). What it proves is narrower: the DLL you have is the
one the author signed, unchanged since. The reproducible build and its hash (below) are the second proof: they show
the signed file holds exactly the public source's code. This self-signature is the project's chosen approach (see
`CODE-SIGNING-POLICY.md` in the repository).

## Check the certificate

The fingerprint printed by

    openssl x509 -in swgrcouch-cert.pem -noout -fingerprint -sha256

must be the one above. Compare it with the copy in the public repository as well:
https://git.jules.my/jules/swgrcouch/src/branch/main/docs/signing/swgrcouch-cert.pem (mirror:
https://github.com/zhinu/swgrcouch/blob/main/docs/signing/swgrcouch-cert.pem).

## Check a DLL

    osslsigncode verify -in swgr_inputfilter.dll -CAfile swgrcouch-cert.pem

ends with `Signature verification: ok` and `Succeeded`. On Windows: Explorer > the DLL's Properties > Digital
Signatures shows *Jules (SWGRCouch)*; Windows marks the certificate as not trusted, which is expected for a
self-signed certificate.

The 1.0.1 DLL:

| file | sha256 |
|---|---|
| signed (in the 1.0.1 zips and the bare `swgr_inputfilter.dll` download) | `41458d0492a29ae1a2fbd3c67f50b8c268a061d364c3d001be163e2ca26d0928` |
| unsigned reproducible build (`SWGRCouch/native/inputfilter/build.sh`, LLVM 23.1.1) | `42e7b2a4cef5e6d8b5ad6c89ae525df98fc921b74941e70b8f872e8b41f7e8b8` |

The signed file is the unsigned build plus an Authenticode signature (with an RFC 3161 time stamp from DigiCert's
public time-stamp service). `osslsigncode remove-signature -in swgr_inputfilter.dll -out unsigned.dll` gives a file
of the same size as the reproducible build that differs from it only in the PE header checksum (3 bytes), which the
signer fills in.
