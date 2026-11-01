// Per-call cost of simdutf's short calls, as calls.zig measures ours: each
// call out of line in a loop, timed with the TSC. Three ways in: the public
// function (through the PLT, then simdutf's dispatch: a load of the active
// implementation and a virtual call), the implementation's virtual function
// with the pointer already loaded (no PLT, no dispatch load), and an empty
// function in a shared library (the PLT and the loop alone).
#include <simdutf.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <x86intrin.h>
extern "C" size_t noop_lib(const char *, size_t);

static inline uint64_t tsc() {
  _mm_lfence();
  uint64_t t = __rdtsc();
  _mm_lfence();
  return t;
}

alignas(4096) static char in_buf[4096];
alignas(4096) static char out_buf[8192];
static const simdutf::implementation *impl;

using Fn = size_t (*)(const char *, size_t, char *);

#define CASE(name, expr)                                                       \
  __attribute__((noinline)) static size_t name(const char *in, size_t n, char *out) {                    \
    (void)out;                                                                 \
    return (expr);                                                             \
  }
CASE(empty, noop_lib(in, n))
CASE(ascii, simdutf::validate_ascii(in, n))
CASE(ascii_impl, impl->validate_ascii(in, n))
CASE(asciiWithErrors, simdutf::validate_ascii_with_errors(in, n).error == 0)
CASE(asciiWithErrors_impl, impl->validate_ascii_with_errors(in, n).error == 0)
CASE(utf8, simdutf::validate_utf8(in, n))
CASE(utf8_impl, impl->validate_utf8(in, n))
CASE(utf8WithErrors, simdutf::validate_utf8_with_errors(in, n).error == 0)
CASE(utf16le, simdutf::validate_utf16le((const char16_t *)in, n / 2))
CASE(utf16le_impl, impl->validate_utf16le((const char16_t *)in, n / 2))
CASE(utf32WithErrors, simdutf::validate_utf32_with_errors((const char32_t *)in, n / 4).error == 0)
CASE(countUtf8, simdutf::count_utf8(in, n))
CASE(countUtf8_impl, impl->count_utf8(in, n))
CASE(countUtf16le, simdutf::count_utf16le((const char16_t *)in, n / 2))
CASE(utf8FromLatin1, simdutf::utf8_length_from_latin1(in, n))
CASE(utf16FromUtf32, simdutf::utf16_length_from_utf32((const char32_t *)in, n / 4))
CASE(latin1ToUtf16le, simdutf::convert_latin1_to_utf16le(in, n, (char16_t *)out))
CASE(latin1ToUtf16le_impl, impl->convert_latin1_to_utf16le(in, n, (char16_t *)out))
CASE(utf16leToLatin1, simdutf::convert_utf16le_to_latin1((const char16_t *)in, n / 2, out))
CASE(utf32ToUtf16le, simdutf::convert_utf32_to_utf16le((const char32_t *)in, n / 4, (char16_t *)out))
CASE(b64encode, simdutf::binary_to_base64(in, n, out))
CASE(b64decode, simdutf::base64_to_binary(in, n, out).error == 0)

template <Fn F> static void bench(const char *name, size_t len) {
  const int rounds = 15;
  const uint64_t iters = 2000000;
  uint64_t t[rounds];
  const char *in = in_buf;
  char *out = out_buf + 2048;
  for (int r = 0; r < rounds; r++) {
    uint64_t start = tsc();
    for (uint64_t i = 0; i < iters; i++) {
      asm volatile("" : "+r"(in) : : "memory");
      size_t x = F(in, len, out);
      asm volatile("" : : "r"(x) : "memory");
    }
    t[r] = tsc() - start;
  }
  std::sort(t, t + rounds);
  double mn = double(t[0]) / iters, med = double(t[rounds / 2]) / iters;
  std::printf("%s/%zu\t%.2f\t%.2f\t%.3f\n", name, len, mn, med, med / 2.6);
}

struct Case { const char *name; void (*b)(const char *, size_t); };
static const Case cases[] = {
    {"empty", bench<empty>},
    {"ascii", bench<ascii>},
    {"ascii_impl", bench<ascii_impl>},
    {"asciiWithErrors", bench<asciiWithErrors>},
    {"asciiWithErrors_impl", bench<asciiWithErrors_impl>},
    {"utf8", bench<utf8>},
    {"utf8_impl", bench<utf8_impl>},
    {"utf8WithErrors", bench<utf8WithErrors>},
    {"utf16le", bench<utf16le>},
    {"utf16le_impl", bench<utf16le_impl>},
    {"utf32WithErrors", bench<utf32WithErrors>},
    {"countUtf8", bench<countUtf8>},
    {"countUtf8_impl", bench<countUtf8_impl>},
    {"countUtf16le", bench<countUtf16le>},
    {"utf8FromLatin1", bench<utf8FromLatin1>},
    {"utf16FromUtf32", bench<utf16FromUtf32>},
    {"latin1ToUtf16le", bench<latin1ToUtf16le>},
    {"latin1ToUtf16le_impl", bench<latin1ToUtf16le_impl>},
    {"utf16leToLatin1", bench<utf16leToLatin1>},
    {"utf32ToUtf16le", bench<utf32ToUtf16le>},
    {"b64encode", bench<b64encode>},
    {"b64decode", bench<b64decode>},
};


int main(int argc, char **argv) {
  const char *filter = argc > 1 ? argv[1] : "";
  const char *alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  for (int i = 0; i < 4096; i++) in_buf[i] = alpha[i % 64];
  std::memset(out_buf, 0, sizeof out_buf);
  simdutf::validate_ascii(in_buf, 1); // the first call picks the implementation
  impl = simdutf::get_active_implementation();
  std::fprintf(stderr, "simdutf %s\n", std::string(impl->name()).c_str());
  for (const Case &cs : cases) {
    if (!std::strstr(cs.name, filter)) continue;
    for (size_t len : {0, 16, 64}) cs.b(cs.name, len);
  }
}
