# imapidle certificate warnings

Look here when the question is what the daemon logs, whether it still connects, or why a bad chain went quiet.

The handshake stays `SSL_VERIFY_NONE`. A missing fingerprint is still fatal. A fingerprint that is new or changed is still stored and the session continues. That is the TOFU record in `known_hosts`. Validity does not override it.

After the chain is archived under `certs/YYYY/HASH-host:port`, the same bytes are checked. The connection is not closed for a failed check. Each problem is one `log_warn` line:

```
host:port: cert server certificate expired 2020-01-02T00:00:00Z
host:port: cert server certificate name does not match mail.example
host:port: cert server certificate has no subjectAltName
host:port: cert not a trusted authority (self signed certificate)
```

`certificate N` is an issuer further up the chain. The list is every problem found on that pass, not the first one.

The quiet period is per certs file, not per host and not per problem. The file's name (`HASH-host:port`) is the key. The first time that file has any problem, every current problem is logged and `cert-warn` stores the epoch. For the next 7 days (`604800` seconds) that file logs nothing, even if a second problem would have appeared. When the week is over the chain is judged again, and if it is still bad every current problem is logged again. A chain with no problems does not write a clock. `cert-warn` is mode 0600. It holds no PEM and no key.

A new chain is a new file, so it warns on first sight. Two hosts with the same chain bytes are two files, because the name includes `host:port`.

The check runs from the handshake that saves the archive, including when the file was already there. It does not scan old files in the background.
