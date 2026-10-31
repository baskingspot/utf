// simdutf's base64 kernels by name, through a C ABI, so the driver can time
// icelake, haswell, and westmere interleaved in one process. Built with the
// dev shell's c++, which matches nixpkgs' libstdc++ build of simdutf.

#include <simdutf.h>

extern "C" {

const void *shim_impl(const char *name) {
  auto impl = simdutf::get_available_implementations()[name];
  return impl && impl->supported_by_runtime_system() ? impl : nullptr;
}

size_t shim_encode(const void *impl, const char *in, size_t n, char *out) {
  return static_cast<const simdutf::implementation *>(impl)->binary_to_base64(
      in, n, out, simdutf::base64_default);
}

size_t shim_decode(const void *impl, const char *in, size_t n, char *out) {
  auto r = static_cast<const simdutf::implementation *>(impl)->base64_to_binary(
      in, n, out, simdutf::base64_default,
      simdutf::last_chunk_handling_options::loose);
  return r.error == simdutf::SUCCESS ? r.count : ~size_t{0};
}
}
