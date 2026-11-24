# Security policy

Packages in this repository run as root on a server. Please report a vulnerability, a way to get code run without a signed index, or a
package that does more than it says, **privately**: open a report under the Security tab of https://github.com/hobnix/official
("Report a vulnerability"). Do not open a public issue for it.

You get an answer within a week. A fix is released by merging into `main`, which publishes a new signed index; the advisory names the affected versions.
How the index is signed and how the key is replaced: the core repository, `config/trusted-keys/README.md`.
