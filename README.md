# utf

SIMD Unicode validation and transcoding, plus base64, in Zig with no C: what simdutf does, as a Zig package.

Despite the name, base64 is a full part of the package, not an extra:

- `utf.validate`: UTF-8, UTF-16LE/BE, UTF-32, and ASCII, with error kind and position on request.
- `utf.convert`: every conversion among UTF-8, UTF-16LE/BE, UTF-32, and Latin-1.
- `utf.length`: the output size each conversion needs, and code point counts.
- `utf.base64`: encode and decode, standard and URL alphabets, with forgiving whitespace handling.

Nothing allocates: callers pass the output buffers. On generic x86-64 builds the SIMD kernels are picked at runtime.

This project is incubating. It is unstable, its API will change, and it is not ready to depend on.

## Work on it

`nix develop` provides the toolchain, and `just ci` runs what CI runs.

## License

MIT. See `LICENSE`.
