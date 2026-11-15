import Foundation

/// Output copied from live runs on 2026-11-14: apple/container 1.7.1
/// (`container build --progress plain`), Docker 28.5.2 (classic `/build`
/// stream) and buildx 0.29.1 (`docker buildx history`) in `docker:28-dind`.
enum BuildHistoryFixtures {
    /// `container build --progress plain` 1.7.1, first build of a 4-line Dockerfile.
    static let appleFirst = #"""
#1 [resolver] fetching image...docker.io/library/alpine:3.20
#1 DONE 0.0s

#2 [internal] load build definition from Dockerfile
#2 transferring dockerfile: 120B done
#2 DONE 0.0s

#3 [internal] load .dockerignore
#3 transferring context: 2B done
#3 DONE 0.0s

#4 [internal] load build context
#4 DONE 0.0s

#5 oci-layout://docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
#5 resolve docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc 0.1s done
#5 sha256:3f26bc2dec0b515f1c2818f6e13a8f1da1f88179a008445d4e587233386bff78 4.09MB / 4.09MB 0.1s done
#5 extracting sha256:3f26bc2dec0b515f1c2818f6e13a8f1da1f88179a008445d4e587233386bff78 0.0s done
#5 DONE 0.2s

#4 [internal] load build context
#4 transferring context: 120B done
#4 DONE 0.0s

#6 [linux/arm64 1/4] RUN echo one > /one
#6 DONE 0.1s

#7 [linux/arm64 2/4] COPY Dockerfile /Dockerfile
#7 DONE 0.0s

#8 [linux/arm64 3/4] RUN echo two > /two
#8 DONE 0.0s

#9 exporting to oci image format
#9 exporting layers 0.0s done
#9 exporting manifest sha256:914b1a583e7b47d436f1119c46da5c4551f8d189b50b2f30103297c4891e0ab1
#9 exporting manifest sha256:914b1a583e7b47d436f1119c46da5c4551f8d189b50b2f30103297c4891e0ab1 done
#9 exporting config sha256:f2524d36479d8182417ff3fd3576e0af37398b229791a6ef39da4bcb34be1e46 done
#9 exporting manifest list sha256:d0112544829e152d1e6b815c178c9eb06e1f3f892d067e444ea44597583a3835 done
#9 sending tarball 0.0s done
#9 DONE 0.0s
docker.io/library/gbh-fixture:1
"""#

    /// The same build again: all Dockerfile steps cached.
    static let appleCached = #"""
#1 [resolver] fetching image...docker.io/library/alpine:3.20
#1 DONE 0.0s

#2 [internal] load build definition from Dockerfile
#2 transferring dockerfile: 120B done
#2 DONE 0.0s

#3 [internal] load .dockerignore
#3 transferring context: 2B done
#3 DONE 0.0s

#4 oci-layout://docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
#4 resolve docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc done
#4 DONE 0.0s

#5 [internal] load build context
#5 transferring context: 120B done
#5 DONE 0.0s

#6 [linux/arm64 1/4] RUN echo one > /one
#6 CACHED

#7 [linux/arm64 2/4] COPY Dockerfile /Dockerfile
#7 CACHED

#8 [linux/arm64 3/4] RUN echo two > /two
#8 CACHED

#9 exporting to oci image format
#9 exporting layers done
#9 exporting manifest sha256:914b1a583e7b47d436f1119c46da5c4551f8d189b50b2f30103297c4891e0ab1 done
#9 exporting config sha256:f2524d36479d8182417ff3fd3576e0af37398b229791a6ef39da4bcb34be1e46 done
#9 exporting manifest list sha256:d0112544829e152d1e6b815c178c9eb06e1f3f892d067e444ea44597583a3835 done
#9 sending tarball 0.0s done
#9 DONE 0.0s
docker.io/library/gbh-fixture:1
"""#

    /// A build that fails at `RUN exit 3` (stderr of the failed CLI run).
    static let appleFailed = #"""
#1 [resolver] fetching image...docker.io/library/alpine:3.20
#1 DONE 0.0s

#2 [internal] load build definition from Dockerfile
#2 transferring dockerfile: 120B done
#2 DONE 0.0s

#3 [internal] load .dockerignore
#3 transferring context: 2B done
#3 DONE 0.0s

#4 oci-layout://docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
#4 resolve docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc done
#4 DONE 0.0s

#5 [linux/arm64 1/3] RUN echo one > /one
#5 CACHED

#6 [linux/arm64 2/3] RUN exit 3
#6 ERROR: process "/bin/sh -c exit 3" did not complete successfully: exit code: 3
------
 > [linux/arm64 2/3] RUN exit 3:
------
Error: unknown: "failed to solve: process "/bin/sh -c exit 3" did not complete successfully: exit code: 3"
"""#

    /// Docker 28.5.2 classic `/build` stream (no cache), as raw JSON lines.
    static let classicFirstStream = #"""
{"stream":"Step 1/4 : FROM alpine:3.20"}
{"stream":"\n"}
{"status":"Pulling from library/alpine","id":"3.20"}
{"status":"Already exists","progressDetail":{},"id":"3f26bc2dec0b"}
{"status":"Digest: sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"}
{"status":"Status: Downloaded newer image for alpine:3.20"}
{"stream":" ---\u003e ab3fe4defd29\n"}
{"stream":"Step 2/4 : RUN echo one \u003e /one"}
{"stream":"\n"}
{"stream":" ---\u003e Running in bdf603a5079a\n"}
{"stream":" ---\u003e Removed intermediate container bdf603a5079a\n"}
{"stream":" ---\u003e b073870af11e\n"}
{"stream":"Step 3/4 : COPY Dockerfile /Dockerfile"}
{"stream":"\n"}
{"stream":" ---\u003e 57b49d5f8510\n"}
{"stream":"Step 4/4 : RUN echo two \u003e /two"}
{"stream":"\n"}
{"stream":" ---\u003e Running in 92b141304704\n"}
{"stream":" ---\u003e Removed intermediate container 92b141304704\n"}
{"stream":" ---\u003e b9b377b8883d\n"}
{"aux":{"ID":"sha256:b9b377b8883dec1a0210359cecfcbd90f99c062d934904f5963926ce3d88e147"}}
{"stream":"Successfully built b9b377b8883d\n"}
{"stream":"Successfully tagged gbhc:1\n"}
"""#

    /// The same classic build again: all steps from cache.
    static let classicCachedStream = #"""
{"stream":"Step 1/4 : FROM alpine:3.20"}
{"stream":"\n"}
{"stream":" ---\u003e ab3fe4defd29\n"}
{"stream":"Step 2/4 : RUN echo one \u003e /one"}
{"stream":"\n"}
{"stream":" ---\u003e Using cache\n"}
{"stream":" ---\u003e b073870af11e\n"}
{"stream":"Step 3/4 : COPY Dockerfile /Dockerfile"}
{"stream":"\n"}
{"stream":" ---\u003e Using cache\n"}
{"stream":" ---\u003e 57b49d5f8510\n"}
{"stream":"Step 4/4 : RUN echo two \u003e /two"}
{"stream":"\n"}
{"stream":" ---\u003e Using cache\n"}
{"stream":" ---\u003e b9b377b8883d\n"}
{"aux":{"ID":"sha256:b9b377b8883dec1a0210359cecfcbd90f99c062d934904f5963926ce3d88e147"}}
{"stream":"Successfully built b9b377b8883d\n"}
{"stream":"Successfully tagged gbhc:1\n"}
"""#

    /// A classic build that fails at `RUN exit 3`.
    static let classicFailedStream = #"""
{"stream":"Step 1/3 : FROM alpine:3.20"}
{"stream":"\n"}
{"stream":" ---\u003e ab3fe4defd29\n"}
{"stream":"Step 2/3 : RUN echo one \u003e /one"}
{"stream":"\n"}
{"stream":" ---\u003e Using cache\n"}
{"stream":" ---\u003e b073870af11e\n"}
{"stream":"Step 3/3 : RUN exit 3"}
{"stream":"\n"}
{"stream":" ---\u003e Running in 73b4c7bca2c7\n"}
{"errorDetail":{"code":3,"message":"The command '/bin/sh -c exit 3' returned a non-zero code: 3"},"error":"The command '/bin/sh -c exit 3' returned a non-zero code: 3"}
"""#

    /// `docker buildx history ls --format json --no-trunc`, buildx 0.29.1.
    static let buildxList = #"""
{"cached_steps":1,"completed_at":"2026-11-14T15:43:05.578935175Z","completed_steps":6,"created_at":"2026-11-14T15:43:05.323942383Z","name":"w/Dockerfile.fail","ref":"default/default/o4kn3a8tluispaxrrvdsh5ypt","status":"Error","total_steps":6}
{"cached_steps":3,"completed_at":"2026-11-14T15:43:05.289937508Z","completed_steps":9,"created_at":"2026-11-14T15:43:05.065933883Z","name":"w","ref":"default/default/27e2j9dcpfc732x57g9lvkzol","status":"Completed","total_steps":9}
{"cached_steps":0,"completed_at":"2026-11-14T15:43:05.025289092Z","completed_steps":9,"created_at":"2026-11-14T15:43:02.088117965Z","name":"w","ref":"default/default/t28o1ba4jhpuuvfrvm9y9r298","status":"Completed","total_steps":9}
"""#

    /// `history inspect --format json` of the failed build (`Error.Stack` removed).
    static let buildxInspectFailed = #"""
{
  "Name": "w/Dockerfile.fail",
  "Ref": "o4kn3a8tluispaxrrvdsh5ypt",
  "Context": "w",
  "Dockerfile": "Dockerfile.fail",
  "StartedAt": "2026-11-14T15:43:05.323942383Z",
  "CompletedAt": "2026-11-14T15:43:05.578935175Z",
  "Duration": 254992792,
  "Status": "failed",
  "Error": {
    "Code": 2,
    "Message": "process \"/bin/sh -c exit 3\" did not complete successfully: exit code: 3",
    "Name": "[3/3] RUN exit 3",
    "Sources": "RG9ja2VyZmlsZS5mYWlsOjMKLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAgMSB8ICAgICBGUk9NIGFscGluZTozLjIwCiAgIDIgfCAgICAgUlVOIGVjaG8gb25lID4gL29uZQogICAzIHwgPj4+IFJVTiBleGl0IDMKICAgNCB8ICAgICAKLS0tLS0tLS0tLS0tLS0tLS0tLS0KCg=="
  },
  "NumCompletedSteps": 6,
  "NumTotalSteps": 6,
  "NumCachedSteps": 1,
  "Config": {
    "Network": "host",
    "ImageResolveMode": "local"
  }
}
"""#

    /// `history inspect --format json` of the first build.
    static let buildxInspectFirst = #"""
{
  "Name": "w",
  "Ref": "t28o1ba4jhpuuvfrvm9y9r298",
  "Context": "w",
  "Dockerfile": "Dockerfile",
  "StartedAt": "2026-11-14T15:43:02.088117965Z",
  "CompletedAt": "2026-11-14T15:43:05.025289092Z",
  "Duration": 2937171127,
  "Status": "completed",
  "NumCompletedSteps": 9,
  "NumTotalSteps": 9,
  "NumCachedSteps": 0,
  "Config": {
    "Network": "host",
    "ImageResolveMode": "local"
  },
  "Materials": [
    {
      "URI": "pkg:docker/alpine@3.20?platform=linux%2Farm64",
      "Digests": [
        "sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
      ]
    }
  ],
  "Attachments": [
    {
      "Digest": "sha256:7f3513b98289aba13e07a7fe76c2cf9119c58a6e1ee1d3813b4adb226b931b9d",
      "Type": "application/vnd.docker.container.image.v1+json"
    },
    {
      "Digest": "sha256:404dd39d338308b7a6080019b4e2345bedd4685cd42c6ea84ceab1db3d3f2b2a",
      "Type": "https://slsa.dev/provenance/v0.2"
    }
  ]
}
"""#

    /// `history logs` of the cached build (ls: 9 total, 3 cached).
    static let buildxLogsCached = #"""
#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 122B done
#1 DONE 0.0s

#2 [internal] load metadata for docker.io/library/alpine:3.20
#2 DONE 0.2s

#3 [internal] load .dockerignore
#3 DONE 0.0s

#4 [1/4] FROM docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
#4 DONE 0.0s

#5 [internal] load build context
#5 transferring context: 31B done
#5 DONE 0.0s

#6 [3/4] COPY Dockerfile /Dockerfile
#6 CACHED

#7 [2/4] RUN echo one > /one
#7 CACHED

#8 [4/4] RUN echo two > /two
#8 CACHED

#9 exporting to image
#9 exporting layers done
#9 writing image sha256:7f3513b98289aba13e07a7fe76c2cf9119c58a6e1ee1d3813b4adb226b931b9d done
#9 naming to docker.io/library/gbh:1 done
#9 DONE 0.0s
"""#

    /// `history logs` of the first build (ls: 9 total, 0 cached).
    static let buildxLogsFirst = #"""
#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 122B done
#1 DONE 0.0s

#2 [internal] load metadata for docker.io/library/alpine:3.20
#2 DONE 1.6s

#3 [internal] load .dockerignore
#3 DONE 0.0s

#4 [internal] load build context
#4 transferring context: 122B done
#4 DONE 0.0s

#5 [1/4] FROM docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
#5 resolve docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc done
#5 sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc 9.23kB / 9.23kB done
#5 sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d 1.03kB / 1.03kB done
#5 sha256:ab3fe4defd29ba6231229a4d41440ac8bde8218e85870e53876277faa24b35c4 628B / 628B done
#5 extracting sha256:3f26bc2dec0b515f1c2818f6e13a8f1da1f88179a008445d4e587233386bff78 0.1s done
#5 sha256:3f26bc2dec0b515f1c2818f6e13a8f1da1f88179a008445d4e587233386bff78 4.09MB / 4.09MB 0.4s done
#5 DONE 0.5s

#6 [2/4] RUN echo one > /one
#6 DONE 0.1s

#7 [3/4] COPY Dockerfile /Dockerfile
#7 DONE 0.0s

#8 [4/4] RUN echo two > /two
#8 DONE 0.0s

#9 exporting to image
#9 exporting layers 0.6s done
#9 writing image sha256:7f3513b98289aba13e07a7fe76c2cf9119c58a6e1ee1d3813b4adb226b931b9d done
#9 naming to docker.io/library/gbh:1 done
#9 DONE 0.6s
"""#

    /// `history logs` of the failed build (ls: 6 total, 1 cached).
    static let buildxLogsFailed = #"""
#1 [internal] load build definition from Dockerfile.fail
#1 transferring dockerfile: 90B done
#1 DONE 0.0s

#2 [internal] load metadata for docker.io/library/alpine:3.20
#2 DONE 0.2s

#3 [internal] load .dockerignore
#3 transferring context: 2B done
#3 DONE 0.0s

#4 [1/3] FROM docker.io/library/alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
#4 DONE 0.0s

#5 [2/3] RUN echo one > /one
#5 CACHED

#6 [3/3] RUN exit 3
#6 ERROR: process "/bin/sh -c exit 3" did not complete successfully: exit code: 3
------
 > [3/3] RUN exit 3:
------
"""#

    /// `docker buildx version`, buildx 0.29.1.
    static let buildxVersion = #"""
github.com/docker/buildx v0.29.1 a32761aeb3debd39be1eca514af3693af0db334b
"""#
}
