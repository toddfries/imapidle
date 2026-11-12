# What invalid means

Look here when the question is which failures are time, which are the signer, and which are something else.

A chain is the leaf first, then each issuer. imapidle archives that order in the `openssl s_client -showcerts` text. `X509_verify_cert(3)` builds and checks one chain and returns failure on the first problem. The error string comes from `X509_STORE_CTX_get_error(3)`. That is why a single verify call is not enough: an expired leaf hides an untrusted issuer. imapidle turns off the library's time check for that call (`X509_V_FLAG_NO_CHECK_TIME`) and judges time itself.

Time is `notBefore` and `notAfter`, compared as UTC timestamps. Later than `notBefore` and earlier than `notAfter` is inside the window. A missing either field is its own warning. Each certificate in the chain is judged, not only the leaf.

The signer check has two layers.

- Neighbors: the leaf's issuer name must be the next certificate's subject, and that next key must verify the leaf's signature. The same pair of checks runs up the chain. When the names differ, the signature is not checked against that next key, because it is the wrong key. When the names match and the signature fails, that failure is its own warning.
- Anchor: the leaf plus the rest of the chain is handed to the trust store. Failure text is kept as LibreSSL reports it. The ones seen for the accounts here are `self signed certificate` and `self signed certificate in certificate chain`. `unable to get local issuer certificate` is the incomplete-chain form. A chain that verifies against `/etc/ssl/cert.pem` produces no authority warning.

Other checks, all independent of the first failure:

- Server name. `X509_check_host` for a DNS name, including a wildcard the library accepts, and the common name only when the certificate has no `subjectAltName`. `X509_check_ip_asc` for an address. Either match is enough for the name. The name still has to be the host imapidle connected to.
- `subjectAltName`. `ssl(8)` says clients that follow current practice require it. A certificate with only a common name warns even when that common name matches.
- Version. X.509 v3 is version value 2. Older certificates cannot carry the name extension.
- Public key. RSA shorter than 2048 bits warns. Elliptic curve shorter than 224 bits warns. A DSA key warns on its type.
- Signature. MD2, MD4, MD5, and SHA-1 warn. SHA-256 does not. LibreSSL's short name looks like `RSA-SHA256`.

Not checked, on purpose: OCSP, CRLs, and certificate transparency. There is no local revocation feed, and a network lookup during the handshake would stall the IDLE loop. Extended key usage is whatever `X509_verify_cert` enforces with its default purpose. There is no extra "must contain serverAuth" warning when the extension is absent.

`openssl x509 -in file -text` and `openssl x509 -checkend` are the commands that show the same fields by hand.
