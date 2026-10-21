# bhpanel-php

Signed PHP packages for BHPanel servers, published at **repo.bhpanel.net**.

These are builds of [Remi Collet's](https://rpms.remirepo.net/) own `scl-phpNN` recipes,
unchanged, made when a fix is out before his package is published - plus, only when
he has not yet carried one back, PHP's own patch. Release numbers stay below Remi's next
package, so his replaces ours as soon as it exists. This is a stop-gap repository,
not a fork of PHP or of Remi's work.

- Built in clean AlmaLinux 9 (and 8, for PHP 5.6-7.3) containers, x86_64 and aarch64.
- Every package and the repository index are signed; BHPanel installs only packages
  signed with the key whose public half is built into the panel, and only `php*`
  packages from this repository.
- Signing runs in the protected `sign` environment and needs the owner's approval.

`tools/make-signing-key.sh` made the signing key, once, on the owner's machine.
