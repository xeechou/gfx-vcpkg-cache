# Graphics vcpkg cache

A common cache for publish vcpkg related packages for my projects.


## Lessons learned

### binary cache ABI instability
The [binary cache](https://learn.microsoft.com/en-us/vcpkg/users/binarycaching) using [ABI Hash](https://learn.microsoft.com/en-us/vcpkg/reference/binarycaching#abi-hash) to check for compatibility. The incomplete list are

- Every file in the port directory.
- The triplet file contents and name.
- The C++ compiler executable file.
- The C compiler executable file.
- The set of features selected.

Even on the same system, (especially Linux distros) sometimes a minor version of bump will resulting obsolete cache, no packages can be reused.


### Solution: vcpkg export
This might not be exactly what you want. [vcpkg export](https://learn.microsoft.com/en-us/vcpkg/commands/export) provides a self contained SDK to use. To use it however you need to disable manifest mode.

``` shell
          cmake -B build -S . -G "${{ matrix.generator }}" \
            -DCMAKE_BUILD_TYPE=Release \
            -DVCPKG_MANIFEST_MODE=OFF \
            -DCMAKE_TOOLCHAIN_FILE="${{ github.workspace }}/vcpkg-export-${{ matrix.triplet }}/scripts/buildsystems/vcpkg.cmake" \
            -DCMAKE_PREFIX_PATH="${{ github.workspace }}/vcpkg-export-${{ matrix.triplet }}/installed/${{ matrix.triplet }}"
```

Disable manifest mode tells the the toolchain file to skip `vcpkg install` and consume directly as it is.


### double/triple binary cache size.

if you have multiple restore keys like I did:

``` yaml
restore-keys: |
   vcpkg-${{ matrix.vcpkgCommitId }}-${{ matrix.triplet }}-${{ steps.vcpkg-json-hash.outputs.hash }}
   vcpkg-${{ matrix.vcpkgCommitId }}-${{ matrix.triplet }}-
```

You are likely to retrieve some obsolete cache (which has a huge list of binaries already). You will get some errors like:

```
Restored 0 package(s) from /home/runner/work/gfx-vcpkg-cache/gfx-vcpkg-cache/vcpkg_cache
```

The cache was rebuilt without cleanup the previous one.

Then the `package binary cache` step later would combine both together and upload a cache that's 2 times the size.

Unfortunately, Microsoft [makes no effort](https://github.com/microsoft/vcpkg/discussions/19589) to cleanup the old binary caches.

**This creates a dilemma** because of the 1st problem above. Either you need to check the binary cache size if it's too big to fail the step, or there need to be some other
