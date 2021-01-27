# Docker containers for micronet dns

This repo contains a nix configuration that builds docker containers.
They are automatically build by hydra, you can find the status [on hydra].


[on hydra]: https://hydra.pingiun.com/jobset/micronet/containers

## How to install a primary authorative server

Download the latest update script, you can find it on the hydra server but it's also stored here: [https://b.j2.lc/update-m-tld.sh].

Place it in a useful place and then add the following line to your crontab:

```cron
*/30 * * * * /usr/local/bin/update-m-tld.sh /var/lib/zones
```

The user running the script should have access to docker, and the `jq` and `curl` programs should be installed.
