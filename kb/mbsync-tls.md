# mbsync TLS

Look here when the question is how `mbsync` connects, or how that differs from imapidle.

`mbsync(1)` picks the hop with `TLSType`:

- `STARTTLS` is the default on port 143, except when `Tunnel` is set.
- `IMAPS` starts TLS immediately, the usual port 993.
- `None` means cleartext. This is the default when `Tunnel` is set, because the tunnel is assumed to already be the secure hop. `Port` is ignored for a tunnel. `Host` is used only if TLS is still negotiated and `CertificateFile` is not what identifies the server.

`TLSVersions` starts at TLS 1.2 and up. `CipherString` applies through TLS 1.2. TLS 1.3 follows the library policy.

Trust has two switches:

- `SystemCertificates yes` (the default) uses the system CA store. `no` means only the CAs listed in `CertificateFile`.
- `CertificateFile` holds two different kinds of PEM, and mbsync treats them differently.
  - A host certificate is matched against the server certificate itself and is trusted even when it is expired. `mbsync-get-cert` can save one. The fingerprint still has to be checked by hand.
  - A CA certificate is a trust anchor. The chain is fully validated. Do not paste the system bundle into this file.

`ClientCertificate` is for a client cert. IMAP accounts here do not use one.

What this means for imapidle: mbsync and imapidle do not share a certificate decision. imapidle pins the SHA256 of the leaf in `known_hosts` and, separately, warns about the chain it archived. A host certificate that mbsync accepts while expired can still draw an imapidle warning. A tunnel with `TLSType None` never shows mbsync a certificate at all.
