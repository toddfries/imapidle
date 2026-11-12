# OpenBSD trust store

Look here when the question is which file is the authority, or what the base system checks before it trusts a peer.

`ssl(8)` is the overview of libssl and libcrypto on this host. Server certificates live under `/etc/ssl`, private keys under `/etc/ssl/private`. A self-signed certificate is what you generate to test. A public name is expected to come from a CA, and `acme-client(1)` is the tool `ssl(8)` points at for that. Browsers match `subjectAltName`, not the subject common name. An example extension is `DNS:example.com`.

`starttls(8)` is the SMTP story, not IMAP. The client sends `STARTTLS` and the rest of the SMTP session runs inside TLS. The page names three properties TLS can give a hop: confidentiality, integrity, and authentication of the peer. It also says that hop is not end-to-end message security. S/MIME or PGP would be, and imapidle does not do those. The certificate recipe on that page is the same OpenSSL one: a private key, then `openssl req -x509`, then `openssl x509 -in file -text` to read it back. Private keys stay unreadable by anyone but the owner.

`openssl verify` walks a chain. `-CAfile` is a PEM bundle of trust anchors. `-CApath` is a directory of `hash.0` links. `-untrusted` supplies intermediates that are not anchors. `-purpose` can demand a use such as a TLS server. The command stops at the first error. imapidle does not shell out to it. It calls `X509_verify_cert(3)` so it can keep going and report the other problems itself.

The bundle imapidle loads is `/etc/ssl/cert.pem`. On this host `CTX_load_verify_locations` succeeds against that path. If that file cannot be read, the warning says so. That is a local failure, not a property of the server certificate.

`tls_config_verify(3)` is the libtls switch. `tls_config_insecure_noverifycert` skips chain and OCSP checks. `tls_config_insecure_noverifyname` skips the server name. `tls_config_insecure_noverifytime` skips notBefore and notAfter. imapidle does not use those calls. The handshake is `SSL_VERIFY_NONE`, so the library itself skips the chain, the name, and the dates. The warning pass asks those three questions and leaves the session up.

`ssl(3)` is the library entry. It points at `tls_init(3)` for the LibreSSL TLS API. imapidle stays on `Net::SSLeay`.
