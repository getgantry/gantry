import Foundation

/// Inspect bodies for the Compose export tests.
enum ComposeExportFixtures {
    /// `container inspect gce-web`, CLI 1.7.1, live run 2026-11-14; only the
    /// home and bind paths were replaced. Started with ports, a volume, a
    /// read-only bind, tmpfs, env, labels, limits, a capability and `--entrypoint`.
    static let appleContainer = #"""
[
  {
    "configuration": {
      "capAdd": [
        "CAP_NET_ADMIN"
      ],
      "capDrop": [],
      "creationDate": "2026-11-14T15:04:06Z",
      "dns": {
        "nameservers": [],
        "options": [],
        "searchDomains": []
      },
      "id": "gce-web",
      "image": {
        "descriptor": {
          "annotations": {
            "com.apple.containerization.image.name": "docker.io/library/alpine:latest",
            "io.containerd.image.name": "docker.io/library/alpine:latest",
            "org.opencontainers.image.ref.name": "docker.io/library/alpine:latest"
          },
          "digest": "sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a",
          "mediaType": "application/vnd.oci.image.index.v1+json",
          "size": 9218
        },
        "reference": "docker.io/library/alpine:latest"
      },
      "initProcess": {
        "arguments": [
          "-c",
          "sleep 3600"
        ],
        "environment": [
          "DB_PASSWORD=hunter2secret",
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          "PRICE=$5",
          "APP_MODE=prod"
        ],
        "executable": "/bin/sh",
        "rlimits": [],
        "supplementalGroups": [],
        "terminal": false,
        "user": {
          "raw": {
            "userString": "0:0"
          }
        },
        "workingDirectory": "/srv"
      },
      "labels": {
        "app": "web",
        "tier": "front"
      },
      "mounts": [
        {
          "destination": "/cache",
          "options": [],
          "source": "tmpfs",
          "type": {
            "tmpfs": {}
          }
        },
        {
          "destination": "/data",
          "options": [],
          "source": "/Users/me/Library/Application Support/com.apple.container/volumes/gce-data/volume.img",
          "type": {
            "volume": {
              "cache": {
                "on": {}
              },
              "format": "ext4",
              "name": "gce-data",
              "sync": {
                "fsync": {}
              }
            }
          }
        },
        {
          "destination": "/srv",
          "options": [
            "ro"
          ],
          "source": "/Users/me/site",
          "type": {
            "virtiofs": {}
          }
        }
      ],
      "networks": [
        {
          "network": "gce-net",
          "options": {
            "hostname": "gce-web",
            "mtu": 1280
          }
        }
      ],
      "platform": {
        "architecture": "arm64",
        "os": "linux",
        "variant": "v8"
      },
      "publishedPorts": [
        {
          "containerPort": 80,
          "count": 1,
          "hostAddress": "127.0.0.1",
          "hostPort": 18080,
          "proto": "tcp"
        },
        {
          "containerPort": 53,
          "count": 1,
          "hostAddress": "0.0.0.0",
          "hostPort": 18053,
          "proto": "udp"
        }
      ],
      "publishedSockets": [],
      "readOnly": false,
      "resources": {
        "cpuOverhead": 1,
        "cpus": 2,
        "memoryInBytes": 536870912
      },
      "rosetta": false,
      "runtimeHandler": "container-runtime-linux",
      "ssh": false,
      "sysctls": {},
      "useInit": false,
      "virtualization": false
    },
    "id": "gce-web",
    "status": {
      "networks": [
        {
          "hostname": "gce-web",
          "ipv4Address": "192.168.65.2/24",
          "ipv4Gateway": "192.168.65.1",
          "ipv6Address": "fd10:ad48:6d04:e5fa:f865:66ff:feff:4ff2/64",
          "macAddress": "fa:65:66:ff:4f:f2",
          "mtu": 1280,
          "network": "gce-net",
          "variant": "reserved"
        }
      ],
      "startedDate": "2026-11-14T15:04:07Z",
      "state": "running"
    }
  }
]
"""#

    /// `container image inspect alpine:latest` from the same run, with only
    /// the arm64 variant and without the layer history.
    static let appleImage = #"""
[
  {
    "configuration": {
      "creationDate": "2026-10-21T22:34:15Z",
      "descriptor": {
        "annotations": {
          "com.apple.containerization.image.name": "docker.io/library/alpine:latest",
          "io.containerd.image.name": "docker.io/library/alpine:latest",
          "org.opencontainers.image.ref.name": "docker.io/library/alpine:latest"
        },
        "digest": "sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a",
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "size": 9218
      },
      "name": "docker.io/library/alpine:latest"
    },
    "id": "be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a",
    "variants": [
      {
        "config": {
          "architecture": "arm64",
          "config": {
            "Cmd": [
              "/bin/sh"
            ],
            "Env": [
              "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            ],
            "WorkingDir": "/"
          },
          "created": "2026-10-21T22:51:39.084385804Z",
          "os": "linux",
          "variant": "v8"
        },
        "digest": "sha256:e311ae748be7f56ae5cba304bc488f0786df68ee507513f654a5cc8597cffb42",
        "platform": {
          "architecture": "arm64",
          "os": "linux",
          "variant": "v8"
        },
        "size": 4192140
      }
    ]
  }
]
"""#

    /// A Docker Engine 27 `GET /containers/{id}/json` body (API 1.47 shape)
    /// of a container made with `docker run`: ports, a named volume, a bind,
    /// an anonymous volume, tmpfs, a user network with an alias and a static
    /// address, a restart policy, a healthcheck, limits and `--rm`.
    static let dockerContainer = #"""
    {
      "Id": "4f9c2a1b7e3d4c5b6a7980112233445566778899aabbccddeeff001122334455",
      "Created": "2026-11-14T10:00:00.000000000Z",
      "Path": "/docker-entrypoint.sh",
      "Args": ["nginx", "-g", "daemon off;"],
      "State": {"Status": "running", "Running": true, "Paused": false, "Restarting": false,
                "OOMKilled": false, "Dead": false, "Pid": 4242, "ExitCode": 0, "Error": "",
                "StartedAt": "2026-11-14T10:00:01Z", "FinishedAt": "0001-01-01T00:00:00Z",
                "Health": {"Status": "healthy", "FailingStreak": 0, "Log": []}},
      "Image": "sha256:aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff00112233",
      "Name": "/web",
      "RestartCount": 0,
      "Platform": "linux",
      "HostConfig": {
        "Binds": ["/srv/site:/usr/share/nginx/html:ro", "web-data:/var/lib/web"],
        "NetworkMode": "backend",
        "PortBindings": {
          "80/tcp": [{"HostIp": "", "HostPort": "8080"}],
          "443/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8443"}],
          "53/udp": [{"HostIp": "0.0.0.0", "HostPort": "5353"}, {"HostIp": "::", "HostPort": "5353"}]
        },
        "RestartPolicy": {"Name": "on-failure", "MaximumRetryCount": 3},
        "AutoRemove": true,
        "CapAdd": ["NET_ADMIN"],
        "CapDrop": null,
        "Dns": [],
        "DnsOptions": [],
        "DnsSearch": [],
        "ExtraHosts": ["host.docker.internal:host-gateway"],
        "GroupAdd": null,
        "IpcMode": "private",
        "PidMode": "",
        "Privileged": false,
        "ReadonlyRootfs": false,
        "SecurityOpt": null,
        "Tmpfs": {"/run": "rw,size=64m"},
        "UTSMode": "",
        "UsernsMode": "",
        "ShmSize": 67108864,
        "Runtime": "runc",
        "Isolation": "",
        "CpuShares": 0,
        "Memory": 536870912,
        "NanoCpus": 1500000000,
        "CpuPeriod": 0,
        "CpuQuota": 0,
        "CpusetCpus": "",
        "Devices": [],
        "MemoryReservation": 0,
        "OomKillDisable": null,
        "PidsLimit": null,
        "Ulimits": [{"Name": "nofile", "Soft": 1024, "Hard": 2048}],
        "LogConfig": {"Type": "json-file", "Config": {}},
        "Init": null,
        "Links": null,
        "VolumesFrom": null
      },
      "Mounts": [
        {"Type": "bind", "Source": "/srv/site", "Destination": "/usr/share/nginx/html", "Mode": "ro",
         "RW": false, "Propagation": "rprivate"},
        {"Type": "volume", "Name": "web-data", "Source": "/var/lib/docker/volumes/web-data/_data",
         "Destination": "/var/lib/web", "Driver": "local", "Mode": "z", "RW": true, "Propagation": ""},
        {"Type": "volume", "Name": "0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c",
         "Source": "/var/lib/docker/volumes/0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c/_data",
         "Destination": "/var/cache/nginx", "Driver": "local", "Mode": "", "RW": true, "Propagation": ""}
      ],
      "Config": {
        "Hostname": "4f9c2a1b7e3d",
        "Domainname": "",
        "User": "",
        "AttachStdin": false,
        "Tty": false,
        "OpenStdin": false,
        "Env": [
          "API_TOKEN=tok_9f8e7d6c5b4a3f2e1d0c",
          "GREETING=yes",
          "PRICE=$5",
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          "NGINX_VERSION=1.27.3"
        ],
        "Cmd": ["nginx", "-g", "daemon off;"],
        "Healthcheck": {
          "Test": ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
          "Interval": 30000000000,
          "Timeout": 5000000000,
          "StartPeriod": 90000000000,
          "Retries": 3
        },
        "Image": "nginx:1.27",
        "Volumes": {"/var/cache/nginx": {}},
        "WorkingDir": "",
        "Entrypoint": ["/docker-entrypoint.sh"],
        "Labels": {
          "maintainer": "NGINX Docker Maintainers <docker-maint@nginx.com>",
          "app": "web",
          "on": "80"
        },
        "StopSignal": "SIGQUIT"
      },
      "NetworkSettings": {
        "Ports": {"80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "8080"}]},
        "Networks": {
          "backend": {
            "IPAMConfig": {"IPv4Address": "172.20.0.10"},
            "Aliases": ["4f9c2a1b7e3d", "frontend"],
            "NetworkID": "n1",
            "Gateway": "172.20.0.1",
            "IPAddress": "172.20.0.10",
            "MacAddress": "02:42:ac:14:00:0a"
          }
        }
      }
    }
    """#

    /// The `GET /images/{id}/json` body of `nginx:1.27`.
    static let dockerImage = #"""
    {
      "Id": "sha256:aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff00112233",
      "RepoTags": ["nginx:1.27"],
      "Config": {
        "Env": [
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          "NGINX_VERSION=1.27.3"
        ],
        "Cmd": ["nginx", "-g", "daemon off;"],
        "Entrypoint": ["/docker-entrypoint.sh"],
        "WorkingDir": "",
        "User": "",
        "Labels": {"maintainer": "NGINX Docker Maintainers <docker-maint@nginx.com>"},
        "StopSignal": "SIGQUIT",
        "ExposedPorts": {"80/tcp": {}}
      }
    }
    """#

    /// Two containers of the Compose project `shop`: `api` depends on `db`
    /// and shares the network of `db`.
    static func composeContainer(id: String, service: String, dependsOn: String = "", networkMode: String = "shop_default") -> String {
        #"""
        {
          "Id": "\#(id)",
          "Name": "/shop-\#(service)-1",
          "Image": "sha256:bb",
          "State": {"Status": "running", "Running": true},
          "HostConfig": {"NetworkMode": "\#(networkMode)", "RestartPolicy": {"Name": "unless-stopped"}},
          "Mounts": [],
          "Config": {
            "Image": "\#(service):latest",
            "Env": ["ROLE=\#(service)"],
            "Cmd": ["run"],
            "Labels": {
              "com.docker.compose.project": "shop",
              "com.docker.compose.service": "\#(service)",
              "com.docker.compose.depends_on": "\#(dependsOn)",
              "team": "core"
            }
          },
          "NetworkSettings": {"Networks": {"shop_default": {"Aliases": ["shop-\#(service)-1", "\#(service)"]}}}
        }
        """#
    }
}
