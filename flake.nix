{
  description = "Docker images for the micronet DNS";

  outputs = { self, nixpkgs }:
    let
      pkgs = import nixpkgs {
        # It only makes sense to build on linux
        system = "x86_64-linux";
      };
      nonRootShadowSetup = { user, uid, gid ? uid }: with pkgs; [
        (
        writeTextDir "etc/shadow" ''
          root:!x:::::::
          ${user}:!:::::::
        ''
        )
        (
        writeTextDir "etc/passwd" ''
          root:x:0:0::/root:${runtimeShell}
          ${user}:x:${toString uid}:${toString gid}::/home/${user}:
        ''
        )
        (
        writeTextDir "etc/group" ''
          root:x:0:
          ${user}:x:${toString gid}:
        ''
        )
        (
        writeTextDir "etc/gshadow" ''
          root:x::
          ${user}:x::
        ''
        )
      ];

      m-zone = pkgs.writeText "m.zone" ''
        $ORIGIN m.
        $TTL 1d

        m.     IN  SOA    ns1.m. hostmaster.pingiun.com. ( 2020101204 1800 900 604800 3600 )
        m.     IN  NS     ns1
        m.     IN  NS     ns2
        ns1    IN  A      159.69.80.121
        ns1    IN  AAAA   2a01:4f8:c2c:d45::2
        ns2    IN  A      51.15.121.66
        ns2    IN  AAAA   2001:bc8:1864:2603::1
      '';

      config = pkgs.writeText "named.conf" ''
        options {
          listen-on port 5353 { any; };
          listen-on-v6 port 5353 { any; };
          allow-query { any; };
          version "[hidden]";
          recursion no;
          edns-udp-size 4096;
          directory "/state";
          dnssec-validation yes;
          disable-empty-zone ".";
        };

        controls { };

        zone "m" {
          type primary;
          file "m.zone";
          allow-transfer { any; };
          notify yes;
        };
      '';

      startupScript = pkgs.writeShellScript "start" ''
        /bin/named -c ${config} -fg
      '';
    in
    {

      defaultPackage.x86_64-linux = with self.packages.x86_64-linux; pkgs.linkFarmFromDrvs "m-tld-config" [
        m-tld-primary
        m-tld-update-script
      ];

      packages.x86_64-linux.m-tld-primary = pkgs.dockerTools.buildImage {
        name = "m-tld-primary";

        contents = [ pkgs.bind ] ++ nonRootShadowSetup { uid = 999; user = "somebody"; };

        runAsRoot = ''
          mkdir -p /state
          mkdir -p /var/run/named

          chown 999:999 /state
          chown 999:999 /var/run/named

          /bin/named-checkconf ${config}
        '';

        config = {
          EntryPoint = [ startupScript ];
          User = "somebody";
          Volumes = {
            "/state" = {};
          };
        };
      };

      packages.x86_64-linux.m-tld-update-script = pkgs.writeScript "update-m-tld.sh" ''
        #! /usr/bin/env bash

        if [[ $# -ne 1 ]]; then
          echo >&2 "First argument should be the zone directory"
          exit 1
        fi

        function updateContainer () {

        }

        zone_dir=$1

        mkdir -p $zone_dir

        curl 'https://raw.githubusercontent.com/micronations-network/registry/main/m.zone' > $zone_dir/m.zone

        old_version=$(docker inspect m-tld-named --format '{{.Config.Image}}')
        if [[ $? != 0 ]]; then
          curl -i -H 'Accept: application/json'
        fi
      '';

    };
}
