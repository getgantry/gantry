// Fixtures cut from real reports made on 2026-11-14 from images exported
// with apple/container 1.7.1. Only some matches and fields are kept.

enum ImageScanFixtures {
    /// Trivy 0.76.2, `trivy image --format json --scanners vuln --input <oci>` of postgres:16-alpine (linux/arm64).
    static let trivyPostgres = #"""
{
 "SchemaVersion": 2,
 "Trivy": {
  "Version": "0.76.2"
 },
 "ReportID": "01a1dab9-8b71-7806-941d-2c7de6917aef",
 "CreatedAt": "2026-11-14T16:42:35.377527+01:00",
 "ArtifactID": "sha256:35726244c51a57338a5a5a5ad8a7e2b18f4ecb8dccd51224cab33ac2ea6a5df0",
 "ArtifactName": "pg-oci",
 "ArtifactType": "container_image",
 "Metadata": {
  "OS": {
   "Family": "alpine",
   "Name": "3.24.4"
  },
  "ImageID": "sha256:35726244c51a57338a5a5a5ad8a7e2b18f4ecb8dccd51224cab33ac2ea6a5df0"
 },
 "Results": [
  {
   "Target": "pg-oci (alpine 3.24.4)",
   "Class": "os-pkgs",
   "Type": "alpine",
   "Vulnerabilities": [
    {
     "VulnerabilityID": "CVE-2026-107364",
     "PkgID": "krb5-libs@1.22.2-r1",
     "PkgName": "krb5-libs",
     "PkgIdentifier": {
      "PURL": "pkg:apk/alpine/krb5-libs@1.22.2-r1?arch=aarch64&distro=3.24.4",
      "UID": "60baca0e3f0fa78d"
     },
     "InstalledVersion": "1.22.2-r1",
     "FixedVersion": "1.22.3-r0",
     "Status": "fixed",
     "PrimaryURL": "https://avd.aquasec.com/nvd/cve-2026-107364",
     "DataSource": {
      "ID": "alpine",
      "Name": "Alpine Secdb",
      "URL": "https://secdb.alpinelinux.org/"
     },
     "Title": "krb5: Unauthenticated KDC DoS based on ASN.1 decoder read overrun",
     "Description": "In all released versions of MIT krb5, an unauthenticated attacker can cause a KDC process to perform a large read overru",
     "Severity": "HIGH",
     "VendorSeverity": {
      "redhat": 3
     }
    },
    {
     "VulnerabilityID": "CVE-2026-112315",
     "PkgID": "krb5-libs@1.22.2-r1",
     "PkgName": "krb5-libs",
     "PkgIdentifier": {
      "PURL": "pkg:apk/alpine/krb5-libs@1.22.2-r1?arch=aarch64&distro=3.24.4",
      "UID": "60baca0e3f0fa78d"
     },
     "InstalledVersion": "1.22.2-r1",
     "FixedVersion": "1.22.3-r0",
     "Status": "fixed",
     "PrimaryURL": "https://avd.aquasec.com/nvd/cve-2026-112315",
     "DataSource": {
      "ID": "alpine",
      "Name": "Alpine Secdb",
      "URL": "https://secdb.alpinelinux.org/"
     },
     "Title": "krb5: MIT krb5 kadmind unauthenticated memory leak DoS in RPCSEC_GSS buffer decode failure",
     "Description": "The RPCSEC_GSS authentication routines in lib/rpc/authgss_prot.c in MIT Kerberos 5 (aka krb5) 1.4 and later do not free ",
     "Severity": "HIGH",
     "CweIDs": [
      "CWE-772"
     ],
     "VendorSeverity": {
      "redhat": 3
     },
     "PublishedDate": "2026-11-09T19:16:40.077Z",
     "LastModifiedDate": "2026-11-13T13:17:41.65Z"
    },
    {
     "VulnerabilityID": "CVE-2026-107708",
     "PkgID": "krb5-libs@1.22.2-r1",
     "PkgName": "krb5-libs",
     "PkgIdentifier": {
      "PURL": "pkg:apk/alpine/krb5-libs@1.22.2-r1?arch=aarch64&distro=3.24.4",
      "UID": "60baca0e3f0fa78d"
     },
     "InstalledVersion": "1.22.2-r1",
     "FixedVersion": "1.22.3-r0",
     "Status": "fixed",
     "PrimaryURL": "https://avd.aquasec.com/nvd/cve-2026-107708",
     "DataSource": {
      "ID": "alpine",
      "Name": "Alpine Secdb",
      "URL": "https://secdb.alpinelinux.org/"
     },
     "Title": "krb5: krb5: Denial of Service via malformed PAC in S4U2Proxy requests",
     "Description": "MIT krb5 through 1.22.2 contains a NULL pointer dereference vulnerability in the KDC's get_pac_princ_with_realm() that r",
     "Severity": "MEDIUM",
     "CweIDs": [
      "CWE-476"
     ],
     "VendorSeverity": {
      "redhat": 2
     },
     "PublishedDate": "2026-10-08T21:17:52.223Z",
     "LastModifiedDate": "2026-10-14T02:16:57.58Z"
    }
   ]
  },
  {
   "Target": "usr/local/bin/gosu",
   "Class": "lang-pkgs",
   "Type": "gobinary",
   "Vulnerabilities": [
    {
     "VulnerabilityID": "CVE-2025-61726",
     "VendorIDs": [
      "GO-2026-4341"
     ],
     "PkgID": "stdlib@v1.24.6",
     "PkgName": "stdlib",
     "PkgIdentifier": {
      "PURL": "pkg:golang/stdlib@v1.24.6",
      "UID": "5a9b484fa87e1a00"
     },
     "InstalledVersion": "v1.24.6",
     "FixedVersion": "1.24.12, 1.25.6",
     "Status": "fixed",
     "PrimaryURL": "https://avd.aquasec.com/nvd/cve-2025-61726",
     "DataSource": {
      "ID": "govulndb",
      "Name": "The Go Vulnerability Database",
      "URL": "https://pkg.go.dev/vuln/"
     },
     "Title": "golang: net/url: Memory exhaustion in query parameter parsing in net/url",
     "Description": "The net/url package does not set a limit on the number of query parameters in a query. While the maximum size of query p",
     "Severity": "HIGH",
     "CweIDs": [
      "CWE-770"
     ],
     "VendorSeverity": {
      "alma": 3,
      "amazon": 3,
      "azure": 2,
      "bitnami": 3,
      "cbl-mariner": 2,
      "oracle-oval": 3,
      "photon": 3,
      "redhat": 3,
      "rocky": 3
     },
     "PublishedDate": "2026-01-28T20:16:09.713Z",
     "LastModifiedDate": "2026-09-17T12:17:11.443Z"
    },
    {
     "VulnerabilityID": "CVE-2026-61801",
     "VendorIDs": [
      "GHSA-mjcv-p78q-w5fw"
     ],
     "PkgID": "github.com/moby/sys/user@v0.1.0",
     "PkgName": "github.com/moby/sys/user",
     "PkgIdentifier": {
      "PURL": "pkg:golang/github.com/moby/sys/user@v0.1.0",
      "UID": "cfd815b74e215fdf"
     },
     "InstalledVersion": "v0.1.0",
     "FixedVersion": "0.4.1",
     "Status": "fixed",
     "SeveritySource": "ghsa",
     "PrimaryURL": "https://avd.aquasec.com/nvd/cve-2026-61801",
     "DataSource": {
      "ID": "ghsa",
      "Name": "GitHub Security Advisory Go",
      "URL": "https://github.com/advisories?query=type%3Areviewed+ecosystem%3Ago"
     },
     "Title": "github.com/moby/sys/user: moby/sys/user: Denial of Service via crafted user or group database files",
     "Description": "The `github.com/moby/sys/user` package provides Go utilities for parsing and looking up entries in Unix-style user and g",
     "Severity": "MEDIUM",
     "CweIDs": [
      "CWE-400"
     ],
     "VendorSeverity": {
      "amazon": 3,
      "azure": 2,
      "ghsa": 2,
      "redhat": 2
     },
     "PublishedDate": "2026-10-08T17:17:17.433Z",
     "LastModifiedDate": "2026-10-08T21:35:53.89Z"
    },
    {
     "VulnerabilityID": "CVE-2026-39824",
     "VendorIDs": [
      "GO-2026-5024"
     ],
     "PkgID": "golang.org/x/sys@v0.1.0",
     "PkgName": "golang.org/x/sys",
     "PkgIdentifier": {
      "PURL": "pkg:golang/golang.org/x/sys@v0.1.0",
      "UID": "11ab2e48c80f8e7d"
     },
     "InstalledVersion": "v0.1.0",
     "FixedVersion": "0.44.0",
     "Status": "fixed",
     "PrimaryURL": "https://avd.aquasec.com/nvd/cve-2026-39824",
     "DataSource": {
      "ID": "govulndb",
      "Name": "The Go Vulnerability Database",
      "URL": "https://pkg.go.dev/vuln/"
     },
     "Title": "Invoking integer overflow in NewNTUnicodeString in golang.org/x/sys/windows",
     "Description": "NewNTUnicodeString does not check for string length overflow. When provided with a string that overflows the maximum siz",
     "Severity": "UNKNOWN",
     "CweIDs": [
      "CWE-190"
     ],
     "PublishedDate": "2026-05-22T20:16:33.057Z",
     "LastModifiedDate": "2026-07-23T16:10:00.137Z"
    },
    {
     "VulnerabilityID": "CVE-2025-68121",
     "VendorIDs": [
      "GO-2026-4337"
     ],
     "PkgID": "stdlib@v1.24.6",
     "PkgName": "stdlib",
     "PkgIdentifier": {
      "PURL": "pkg:golang/stdlib@v1.24.6",
      "UID": "5a9b484fa87e1a00"
     },
     "InstalledVersion": "v1.24.6",
     "FixedVersion": "1.24.13, 1.25.7, 1.26.0-rc.3",
     "Status": "fixed",
     "SeveritySource": "nvd",
     "PrimaryURL": "https://avd.aquasec.com/nvd/cve-2025-68121",
     "DataSource": {
      "ID": "govulndb",
      "Name": "The Go Vulnerability Database",
      "URL": "https://pkg.go.dev/vuln/"
     },
     "Title": "crypto/tls: crypto/tls: Incorrect certificate validation during TLS session resumption",
     "Description": "During session resumption in crypto/tls, if the underlying Config has its ClientCAs or RootCAs fields mutated between th",
     "Severity": "CRITICAL",
     "CweIDs": [
      "CWE-295"
     ],
     "VendorSeverity": {
      "alma": 3,
      "amazon": 2,
      "azure": 2,
      "bitnami": 4,
      "cbl-mariner": 2,
      "nvd": 4,
      "oracle-oval": 3,
      "photon": 4,
      "redhat": 2,
      "rocky": 3,
      "ubuntu": 2
     },
     "PublishedDate": "2026-02-05T18:16:10.857Z",
     "LastModifiedDate": "2026-06-17T09:58:33.833Z"
    }
   ]
  }
 ]
}
"""#

    /// Trivy 0.76.2 on alpine:latest: one finding, and the package list of the result.
    static let trivyAlpine = #"""
{
 "SchemaVersion": 2,
 "Trivy": {
  "Version": "0.76.2"
 },
 "ArtifactName": "al-oci",
 "ArtifactType": "container_image",
 "Results": [
  {
   "Target": "al-oci (alpine 3.24.3)",
   "Class": "os-pkgs",
   "Type": "alpine",
   "Packages": [
    {
     "ID": "alpine-baselayout@3.7.2-r1",
     "Name": "alpine-baselayout",
     "Identifier": {
      "PURL": "pkg:apk/alpine/alpine-baselayout@3.7.2-r1?arch=aarch64&distro=3.24.3",
      "UID": "304a3a90fc88fa6b"
     },
     "Version": "3.7.2-r1",
     "Arch": "aarch64",
     "SrcName": "alpine-baselayout",
     "SrcVersion": "3.7.2-r1",
     "Licenses": [
      "GPL-2.0-only"
     ],
     "Maintainer": "Natanael Copa <ncopa@alpinelinux.org>",
     "DependsOn": [
      "alpine-baselayout-data@3.7.2-r1",
      "busybox-binsh@1.37.0-r31"
     ],
     "Layer": {
      "Digest": "sha256:d3531b7a4f217bdc3426c57bcff84c170f086f456a39689d4a615c6d026c4be0",
      "DiffID": "sha256:a278e6f39431cd0ed74238a3d377893ad0d905d68b676bf9a65529080669756b"
     },
     "Digest": "sha1:ee13a18ee7e29d75872017403d59c0484dacd963",
     "InstalledFiles": [
      "etc/motd",
      "etc/crontabs/root",
      "etc/modprobe.d/aliases.conf",
      "etc/modprobe.d/blacklist.conf",
      "etc/modprobe.d/i386.conf",
      "etc/profile.d/20locale.sh",
      "etc/profile.d/README",
      "etc/profile.d/color_prompt.sh.disabled",
      "usr/lib/sysctl.d/00-alpine.conf",
      "var/lock",
      "var/run",
      "var/spool/mail",
      "var/spool/cron/crontabs"
     ],
     "AnalyzedBy": "apk"
    }
   ],
   "Vulnerabilities": [
    {
     "VulnerabilityID": "CVE-2026-4738",
     "PkgID": "zlib@1.3.2-r1",
     "PkgName": "zlib",
     "PkgIdentifier": {
      "PURL": "pkg:apk/alpine/zlib@1.3.2-r1?arch=aarch64&distro=3.24.3",
      "UID": "d5fa52fdcd14f177"
     },
     "InstalledVersion": "1.3.2-r1",
     "FixedVersion": "1.4-r0",
     "Status": "fixed",
     "Layer": {
      "Digest": "sha256:d3531b7a4f217bdc3426c57bcff84c170f086f456a39689d4a615c6d026c4be0",
      "DiffID": "sha256:a278e6f39431cd0ed74238a3d377893ad0d905d68b676bf9a65529080669756b"
     },
     "PrimaryURL": "https://avd.aquasec.com/nvd/cve-2026-4738",
     "DataSource": {
      "ID": "alpine",
      "Name": "Alpine Secdb",
      "URL": "https://secdb.alpinelinux.org/"
     },
     "Fingerprint": "sha256:9c503172453303f3525a71a2a569f69a950a5f0305922d6561d5ac0299f3db60",
     "Title": "Improper Restriction of Operations within the Bounds of a Memory Buffe ...",
     "Description": "Improper Restriction of Operations within the Bounds of a Memory Buffer vulnerability in OSGeo gdal (frmts/zlib/contrib/infback9 modules). This vulnerability is associated with program files inftree9.C‎.\n\nThis issue affects gdal: before 3.11.0.",
     "Severity": "MEDIUM",
     "CweIDs": [
      "CWE-119"
     ],
     "VendorSeverity": {
      "bitnami": 4,
      "julia": 4,
      "ubuntu": 2
     },
     "CVSS": {
      "bitnami": {
       "V40Vector": "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:P/VC:H/VI:H/VA:H/SC:H/SI:H/SA:H/E:A/S:P/AU:Y/R:U/V:C/RE:L/U:Amber",
       "V40Score": 9.4
      },
      "julia": {
       "V40Vector": "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:P/VC:H/VI:H/VA:H/SC:H/SI:H/SA:H/E:A/S:P/AU:Y/R:U/V:C/RE:L/U:Amber",
       "V40Score": 9.4
      }
     },
     "References": [
      "https://github.com/OSGeo/gdal/pull/12244",
      "https://github.com/advisories/GHSA-hp6p-5qh5-w9fj",
      "https://nvd.nist.gov/vuln/detail/CVE-2026-4738",
      "https://www.cve.org/CVERecord?id=CVE-2026-4738"
     ],
     "PublishedDate": "2026-03-24T04:17:29Z",
     "LastModifiedDate": "2026-06-17T10:57:09.03Z"
    }
   ]
  }
 ]
}
"""#

    /// Grype 0.121.3, `grype oci-dir:<oci> -o json` of postgres:16-alpine (linux/arm64).
    static let grypePostgres = #"""
{
 "matches": [
  {
   "vulnerability": {
    "id": "CVE-2026-4738",
    "dataSource": "https://security.alpinelinux.org/vuln/CVE-2026-4738",
    "namespace": "alpine:distro:alpine:3.24",
    "severity": "Critical",
    "urls": [],
    "fix": {
     "versions": [
      "1.4-r0"
     ],
     "state": "fixed",
     "available": [
      {
       "version": "1.4-r0",
       "date": "2026-11-07",
       "kind": "first-observed"
      }
     ]
    }
   },
   "relatedVulnerabilities": [
    {
     "id": "CVE-2026-4738",
     "dataSource": "https://nvd.nist.gov/vuln/detail/CVE-2026-4738",
     "namespace": "nvd:cpe",
     "severity": "Critical",
     "description": "Improper Restriction of Operations within the Bounds of a Memory Buffer vulnerability in OSGeo gdal (frmts/zlib/contrib/infback9 modules). This vulnerability is associated with program files inftree9.C‎.\n\nThis issue affects gdal: before 3.11.0."
    }
   ],
   "artifact": {
    "id": "b2ce6742f153cebc",
    "name": "zlib",
    "version": "1.3.2-r1",
    "type": "apk",
    "language": "",
    "purl": "pkg:apk/alpine/zlib@1.3.2-r1?arch=aarch64&distro=alpine-3.24.4"
   }
  },
  {
   "vulnerability": {
    "id": "CVE-2026-125350",
    "dataSource": "https://security.alpinelinux.org/vuln/CVE-2026-125350",
    "namespace": "alpine:distro:alpine:3.24",
    "severity": "High",
    "urls": [],
    "fix": {
     "versions": [
      "1.1.43-r4"
     ],
     "state": "fixed",
     "available": [
      {
       "version": "1.1.43-r4",
       "date": "2026-11-11",
       "kind": "first-observed"
      }
     ]
    }
   },
   "relatedVulnerabilities": [
    {
     "id": "CVE-2026-125350",
     "dataSource": "https://nvd.nist.gov/vuln/detail/CVE-2026-125350",
     "namespace": "nvd:cpe",
     "severity": "High",
     "description": "Use after free in XML in Google Chrome prior to 157.0.8103.50 allowed a remote attacker to execute arbitrary code inside the sandbox via a crafted HTML page. (Chromium security severity: High)"
    }
   ],
   "artifact": {
    "id": "bc4b2f8513f79bd4",
    "name": "libxslt",
    "version": "1.1.43-r3",
    "type": "apk",
    "language": "",
    "purl": "pkg:apk/alpine/libxslt@1.1.43-r3?arch=aarch64&distro=alpine-3.24.4"
   }
  },
  {
   "vulnerability": {
    "id": "CVE-2026-112314",
    "dataSource": "https://security.alpinelinux.org/vuln/CVE-2026-112314",
    "namespace": "alpine:distro:alpine:3.24",
    "severity": "High",
    "urls": [],
    "fix": {
     "versions": [
      "1.22.3-r0"
     ],
     "state": "fixed",
     "available": [
      {
       "version": "1.22.3-r0",
       "date": "2026-11-11",
       "kind": "first-observed"
      }
     ]
    }
   },
   "relatedVulnerabilities": [
    {
     "id": "CVE-2026-112314",
     "dataSource": "https://nvd.nist.gov/vuln/detail/CVE-2026-112314",
     "namespace": "nvd:cpe",
     "severity": "High",
     "description": "clnttcp_call() in lib/rpc/clnt_tcp.c in MIT Kerberos 5 (aka krb5) does not free the RPC reply verifier between retries, which allows remote attackers to cause a denial of service (memory leak in GSS-RPC client programs) by injecting RPC replies with mismatched XIDs or by triggering authentication retries."
    }
   ],
   "artifact": {
    "id": "df04f2770503ea7a",
    "name": "krb5-libs",
    "version": "1.22.2-r1",
    "type": "apk",
    "language": "",
    "purl": "pkg:apk/alpine/krb5-libs@1.22.2-r1?arch=aarch64&distro=alpine-3.24.4&upstream=krb5"
   }
  },
  {
   "vulnerability": {
    "id": "CVE-2026-112319",
    "dataSource": "https://security.alpinelinux.org/vuln/CVE-2026-112319",
    "namespace": "alpine:distro:alpine:3.24",
    "severity": "Medium",
    "urls": [],
    "fix": {
     "versions": [
      "1.22.3-r0"
     ],
     "state": "fixed",
     "available": [
      {
       "version": "1.22.3-r0",
       "date": "2026-11-11",
       "kind": "first-observed"
      }
     ]
    }
   },
   "relatedVulnerabilities": [
    {
     "id": "CVE-2026-112319",
     "dataSource": "https://nvd.nist.gov/vuln/detail/CVE-2026-112319",
     "namespace": "nvd:cpe",
     "severity": "Medium",
     "description": "The GSS-RPC layer in MIT Kerberos 5 (aka krb5) does not enforce size limits on XDR-decoded data, which allows remote authenticated users to cause a denial of service (memory exhaustion or excessive CPU consumption in kadmind) via crafted RPC requests that trigger unbounded memory allocations during XDR decoding."
    }
   ],
   "artifact": {
    "id": "df04f2770503ea7a",
    "name": "krb5-libs",
    "version": "1.22.2-r1",
    "type": "apk",
    "language": "",
    "purl": "pkg:apk/alpine/krb5-libs@1.22.2-r1?arch=aarch64&distro=alpine-3.24.4&upstream=krb5"
   }
  },
  {
   "vulnerability": {
    "id": "CVE-2025-60876",
    "dataSource": "https://nvd.nist.gov/vuln/detail/CVE-2025-60876",
    "namespace": "nvd:cpe",
    "severity": "Medium",
    "urls": [
     "https://gist.github.com/subyumatest/41554af6a72aedaacaec026adc311092",
     "https://lists.busybox.net/pipermail/busybox/attachments/20250823/ccdc96ef/attachment-0001.htm",
     "https://lists.busybox.net/pipermail/busybox/attachments/20250828/e7f90492/attachment.htm",
     "https://cert-portal.siemens.com/productcert/html/ssa-253495.html"
    ],
    "fix": {
     "versions": [],
     "state": ""
    }
   },
   "relatedVulnerabilities": [],
   "artifact": {
    "id": "6cb7d4b8a66ff2bf",
    "name": "busybox",
    "version": "1.37.0-r31",
    "type": "apk",
    "language": "",
    "purl": "pkg:apk/alpine/busybox@1.37.0-r31?arch=aarch64&distro=alpine-3.24.4"
   }
  },
  {
   "vulnerability": {
    "id": "CVE-2026-107364",
    "dataSource": "https://security.alpinelinux.org/vuln/CVE-2026-107364",
    "namespace": "alpine:distro:alpine:3.24",
    "severity": "Unknown",
    "urls": [],
    "fix": {
     "versions": [
      "1.22.3-r0"
     ],
     "state": "fixed",
     "available": [
      {
       "version": "1.22.3-r0",
       "date": "2026-11-11",
       "kind": "first-observed"
      }
     ]
    }
   },
   "relatedVulnerabilities": [
    {
     "id": "CVE-2026-107364",
     "dataSource": "nvd",
     "namespace": "nvd:cpe",
     "severity": "Unknown",
     "description": null
    }
   ],
   "artifact": {
    "id": "df04f2770503ea7a",
    "name": "krb5-libs",
    "version": "1.22.2-r1",
    "type": "apk",
    "language": "",
    "purl": "pkg:apk/alpine/krb5-libs@1.22.2-r1?arch=aarch64&distro=alpine-3.24.4&upstream=krb5"
   }
  },
  {
   "vulnerability": {
    "id": "GHSA-mjcv-p78q-w5fw",
    "dataSource": "https://github.com/advisories/GHSA-mjcv-p78q-w5fw",
    "namespace": "github:language:go",
    "severity": "Medium",
    "urls": [
     "https://github.com/moby/sys/security/advisories/GHSA-mjcv-p78q-w5fw",
     "https://github.com/moby/sys/pull/221",
     "https://github.com/moby/sys/commit/85a71bbe1faa36c552a960e6a5f3d0cfb632fbbe"
    ],
    "fix": {
     "versions": [
      "0.4.1"
     ],
     "state": "fixed",
     "available": [
      {
       "version": "0.4.1",
       "date": "2026-10-08",
       "kind": "first-observed"
      }
     ]
    }
   },
   "relatedVulnerabilities": [
    {
     "id": "CVE-2026-61801",
     "dataSource": "https://nvd.nist.gov/vuln/detail/CVE-2026-61801",
     "namespace": "nvd:cpe",
     "severity": "Medium",
     "description": "The `github.com/moby/sys/user` package provides Go utilities for parsing and looking up entries in Unix-style user and group database files. Versions before 0.4.1 do not sufficiently limit entries when parsing `/etc/passwd`- or `/etc/group`-style files, allowing an attacker who can supply a specially crafted file to cause excessive memory consumption and potentially terminate the affected process due to an out-of-memory condition. This issue is patched in version 0.4.1. As a workaround, avoid parsing attacker-controlled user or group database files, or validate and limit untrusted input before parsing it."
    }
   ],
   "artifact": {
    "id": "9f98af917860f056",
    "name": "github.com/moby/sys/user",
    "version": "v0.1.0",
    "type": "go-module",
    "language": "go",
    "purl": "pkg:golang/github.com/moby/sys/user@v0.1.0"
   }
  }
 ],
 "descriptor": {
  "name": "grype",
  "version": "0.121.3"
 }
}
"""#

    /// Grype 0.121.3 on alpine:latest: one CVE that hits three packages.
    static let grypeAlpine = #"""
{
 "matches": [
  {
   "vulnerability": {
    "id": "CVE-2026-4738",
    "dataSource": "https://security.alpinelinux.org/vuln/CVE-2026-4738",
    "namespace": "alpine:distro:alpine:3.24",
    "severity": "Critical",
    "urls": [],
    "fix": {
     "versions": [
      "1.4-r0"
     ],
     "state": "fixed",
     "available": [
      {
       "version": "1.4-r0",
       "date": "2026-11-07",
       "kind": "first-observed"
      }
     ]
    }
   },
   "relatedVulnerabilities": [
    {
     "id": "CVE-2026-4738",
     "dataSource": "https://nvd.nist.gov/vuln/detail/CVE-2026-4738",
     "namespace": "nvd:cpe",
     "severity": "Critical",
     "description": "Improper Restriction of Operations within the Bounds of a Memory Buffer vulnerability in OSGeo gdal (frmts/zlib/contrib/infback9 modules). This vulnerability is associated with program files inftree9.C‎.\n\nThis issue affects gdal: before 3.11.0."
    }
   ],
   "artifact": {
    "id": "b2ce6742f153cebc",
    "name": "zlib",
    "version": "1.3.2-r1",
    "type": "apk",
    "language": "",
    "purl": "pkg:apk/alpine/zlib@1.3.2-r1?arch=aarch64&distro=alpine-3.24.3"
   }
  },
  {
   "vulnerability": {
    "id": "CVE-2025-60876",
    "dataSource": "https://nvd.nist.gov/vuln/detail/CVE-2025-60876",
    "namespace": "nvd:cpe",
    "severity": "Medium",
    "urls": [
     "https://gist.github.com/subyumatest/41554af6a72aedaacaec026adc311092",
     "https://lists.busybox.net/pipermail/busybox/attachments/20250823/ccdc96ef/attachment-0001.htm",
     "https://lists.busybox.net/pipermail/busybox/attachments/20250828/e7f90492/attachment.htm",
     "https://cert-portal.siemens.com/productcert/html/ssa-253495.html"
    ],
    "fix": {
     "versions": [],
     "state": ""
    }
   },
   "relatedVulnerabilities": [],
   "artifact": {
    "id": "6cb7d4b8a66ff2bf",
    "name": "busybox",
    "version": "1.37.0-r31",
    "type": "apk",
    "language": "",
    "purl": "pkg:apk/alpine/busybox@1.37.0-r31?arch=aarch64&distro=alpine-3.24.3"
   }
  },
  {
   "vulnerability": {
    "id": "CVE-2025-60876",
    "dataSource": "https://nvd.nist.gov/vuln/detail/CVE-2025-60876",
    "namespace": "nvd:cpe",
    "severity": "Medium",
    "urls": [
     "https://gist.github.com/subyumatest/41554af6a72aedaacaec026adc311092",
     "https://lists.busybox.net/pipermail/busybox/attachments/20250823/ccdc96ef/attachment-0001.htm",
     "https://lists.busybox.net/pipermail/busybox/attachments/20250828/e7f90492/attachment.htm",
     "https://cert-portal.siemens.com/productcert/html/ssa-253495.html"
    ],
    "fix": {
     "versions": [],
     "state": ""
    }
   },
   "relatedVulnerabilities": [],
   "artifact": {
    "id": "896e64dcadcbdc1c",
    "name": "busybox-binsh",
    "version": "1.37.0-r31",
    "type": "apk",
    "language": "",
    "purl": "pkg:apk/alpine/busybox-binsh@1.37.0-r31?arch=aarch64&distro=alpine-3.24.3&upstream=busybox"
   }
  },
  {
   "vulnerability": {
    "id": "CVE-2025-60876",
    "dataSource": "https://nvd.nist.gov/vuln/detail/CVE-2025-60876",
    "namespace": "nvd:cpe",
    "severity": "Medium",
    "urls": [
     "https://gist.github.com/subyumatest/41554af6a72aedaacaec026adc311092",
     "https://lists.busybox.net/pipermail/busybox/attachments/20250823/ccdc96ef/attachment-0001.htm",
     "https://lists.busybox.net/pipermail/busybox/attachments/20250828/e7f90492/attachment.htm",
     "https://cert-portal.siemens.com/productcert/html/ssa-253495.html"
    ],
    "fix": {
     "versions": [],
     "state": ""
    }
   },
   "relatedVulnerabilities": [],
   "artifact": {
    "id": "b98318920cf4fa59",
    "name": "ssl_client",
    "version": "1.37.0-r31",
    "type": "apk",
    "language": "",
    "purl": "pkg:apk/alpine/ssl_client@1.37.0-r31?arch=aarch64&distro=alpine-3.24.3&upstream=busybox"
   }
  }
 ],
 "descriptor": {
  "name": "grype",
  "version": "0.121.3"
 }
}
"""#

    /// Trivy 0.76.2 on ghcr.io/apple/containerization/vminit:0.53.0: no OS and no
    /// packages, so the report has no `Results` key.
    static let trivyNoResults = #"""
{
 "SchemaVersion": 2,
 "Trivy": {
  "Version": "0.76.2"
 },
 "ReportID": "01a1dacc-4056-76ca-8f85-f565644efac6",
 "CreatedAt": "2026-11-14T17:03:01.334448+01:00",
 "ArtifactID": "sha256:dc227619c044f206c5182fbb0211b029cb100f7d6a036c2a6671fe9e78c4d9e6",
 "ArtifactName": "vm-oci",
 "ArtifactType": "container_image"
}
"""#
}
