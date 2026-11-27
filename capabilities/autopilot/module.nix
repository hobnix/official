# The capability "autopilot" (a trial, hobnix/core#1374). UNVERIFIED: never evaluated on a server. Only the folder the jobs will keep their
# state in; the timer comes with the queue. Loaded only while `autopilot` is in `capabilities` of machine.toml.
{ ... }:

{
  systemd.tmpfiles.rules = [ "d /var/lib/hs/autopilot 0700 root root -" ];
}
