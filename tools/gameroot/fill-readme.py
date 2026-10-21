#!/usr/bin/env python3
# tools/gameroot/fill-readme.py SRC OUT VERSION DLLSTATE DLLSHA CERTFP - the gameroot install text (package.sh):
# @VERSION@ / @DLLSTATE@ / @DLLSHA@ filled in, @DLLVERIFY@ (a line of its own) = how to check the DLL's signature when
# CERTFP (the certificate's SHA-256 fingerprint) is given (the signed DLL, its certificate next to it), else a note for
# an unsigned build. Written with CRLF line ends (Notepad on Windows).
import sys

src, out, ver, state, sha, fp = sys.argv[1:7]
if fp:
    verify = (
        "  Check the signature (optional). The certificate swgrcouch-cert.pem is next to the DLL, in\n"
        "  ue4ss\\Mods\\SWGRCouch\\native\\.\n"
        "    Windows: right-click swgr_inputfilter.dll > Properties > Digital Signatures: the signer is\n"
        "      \"Jules (SWGRCouch)\". Windows says the certificate is not trusted (\"unknown publisher\"): that is\n"
        "      expected, it is the author's own self-signed certificate, not one from a certificate authority.\n"
        "    Linux / Steam Deck, in that native folder:\n"
        "      osslsigncode verify -CAfile swgrcouch-cert.pem -in swgr_inputfilter.dll\n"
        "      ends with \"Signature verification: ok\" and \"Succeeded\" (without -CAfile it says \"failed\":\n"
        "      expected for a self-signed certificate).\n"
        "    The certificate's SHA-256 fingerprint\n"
        "      (openssl x509 -in swgrcouch-cert.pem -noout -fingerprint -sha256):\n"
        "      " + fp + "\n"
        "      the same as in docs/signing/README.md in the repository.\n")
else:
    verify = "  This build is unsigned: compare its sha256 above with the one on the release page.\n"
t = open(src, encoding="utf-8").read()
if "@DLLVERIFY@\n" not in t:
    sys.exit("fill-readme.py: no @DLLVERIFY@ line in " + src)
t = t.replace("@DLLVERIFY@\n", verify)
for k, v in (("@VERSION@", ver), ("@DLLSTATE@", state), ("@DLLSHA@", sha)):
    t = t.replace(k, v)
with open(out, "w", encoding="utf-8", newline="\r\n") as f:
    f.write(t)
