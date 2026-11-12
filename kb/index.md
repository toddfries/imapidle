# Certificate notes for imapidle

Read this index, then open one file. The notes are what matters for this
program. They are not a copy of the manual pages.

| Question | File |
| --- | --- |
| How does mbsync decide TLS, and which certificates does it trust? | [mbsync-tls.md](mbsync-tls.md) |
| Where does OpenBSD keep the trust store, and what do starttls(8) and ssl(8) actually check? | [openbsd-trust.md](openbsd-trust.md) |
| What makes an X.509 chain fail for time, name, or signature? | [x509-checks.md](x509-checks.md) |
| What does imapidle warn about, and when does it stay quiet? | [imapidle-warnings.md](imapidle-warnings.md) |

Manuals these notes came from, and the pages those manuals name next:

- `mbsync(1)` — `TLSType`, `SystemCertificates`, `CertificateFile`, `Tunnel`
- `starttls(8)` — see also `mail(1)`, `openssl(1)`, `smtpd(8)`, `ssl(8)`
- `ssl(8)` — see also `acme-client(1)`, `openssl(1)`, `ssh(1)`, `ssl(3)`, `httpd(8)`, `isakmpd(8)`, `rc(8)`, `smtpd(8)`, `sshd(8)`, `starttls(8)`
- `ssl(3)` — see also `openssl(1)`, `crypto(3)`, `tls_init(3)`
- `openssl(1)` verify, x509, and s_client — see also `acme-client(1)`, `nc(1)`, `openssl.cnf(5)`, `x509v3.cnf(5)`, `ssl(8)`, `starttls(8)`. Files: `/etc/ssl/`, `/etc/ssl/private/`, `/etc/ssl/openssl.cnf`, `/etc/ssl/x509v3.cnf`
- `X509_verify_cert(3)` — see also `X509_STORE_CTX_get_error(3)`, `X509_STORE_CTX_new(3)`
- `tls_config_verify(3)` — libtls can turn off cert, name, and time checks separately. imapidle does not use libtls.

imapidle speaks TLS with `IO::Socket::SSL` and LibreSSL (`Net::SSLeay`), not with libtls.
