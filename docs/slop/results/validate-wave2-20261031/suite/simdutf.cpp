// simdutf arm for the scratch validation suite: `vb-simdutf KERNEL [FILTER]`
// times each row of /home/user/vb/in/manifest with simdutf's KERNEL
// (icelake, haswell, westmere, fallback), sizing loops as testing.B does.
#include <simdutf.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static const simdutf::implementation *impl;

// The pointer escapes every call, so no call is hoisted out of the loop.
template <typename T> static T *ESC(T *x) {
  asm volatile("" : "+r"(x));
  return x;
}

template <typename F> static uint64_t timed(F f, uint64_t n, size_t &ok) {
  auto start = std::chrono::steady_clock::now();
  for (uint64_t i = 0; i < n; i++) {
    asm volatile("" : : : "memory");
    ok += f();
  }
  auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - start)
                .count();
  return ns > 0 ? uint64_t(ns) : 1;
}

template <typename F>
static void bench(const std::string &row, size_t bytes, F f) {
  uint64_t goal = 100'000'000;
  if (const char *ms = std::getenv("BENCHTIME_MS"))
    goal = std::strtoull(ms, nullptr, 10) * 1'000'000;
  size_t ok = 0;
  uint64_t n = 1, ns = timed(f, 1, ok);
  while (ns < goal && n < 1'000'000'000) {
    uint64_t next = ns > 0 ? goal * n / ns : 100 * n;
    next += next / 5;
    if (next > 100 * n) next = 100 * n;
    if (next <= n) next = n + 1;
    n = next;
    ns = timed(f, n, ok);
  }
  double nsop = double(ns) / double(n);
  std::printf("%s\t%llu\t%.2f ns/op\t%.2f MB/s\n", row.c_str(),
              (unsigned long long)n, nsop, double(bytes) * 1e3 / nsop);
  asm volatile("" : : "g"(ok) : "memory");
}

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  impl = simdutf::get_available_implementations()[argv[1]];
  if (!impl || !impl->supported_by_runtime_system()) {
    std::fprintf(stderr, "kernel %s unavailable\n", argv[1]);
    return 1;
  }
  const char *filter = argc > 2 ? argv[2] : "";
  std::ifstream manifest("/home/user/vb/in/manifest");
  std::string line;
  while (std::getline(manifest, line)) {
    std::istringstream ls(line);
    std::string row, func, path;
    std::getline(ls, row, '\t');
    std::getline(ls, func, '\t');
    std::getline(ls, path, '\t');
    if (row.find(filter) == std::string::npos) continue;
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    size_t len = f.tellg();
    f.seekg(0);
    char *base = static_cast<char *>(std::aligned_alloc(64, len + 128));
    char *p = base + 16;
    f.read(p, std::streamsize(len));
    const char16_t *u16 = reinterpret_cast<const char16_t *>(p);
    const char32_t *u32 = reinterpret_cast<const char32_t *>(p);
    if (func == "utf8")
      bench(row, len, [&] { const char *q = p; return impl->validate_utf8(ESC(q), len); });
    else if (func == "utf8_with_errors")
      bench(row, len, [&] { const char *q = p; return impl->validate_utf8_with_errors(ESC(q), len).error == simdutf::SUCCESS; });
    else if (func == "ascii")
      bench(row, len, [&] { const char *q = p; return impl->validate_ascii(ESC(q), len); });
    else if (func == "ascii_with_errors")
      bench(row, len, [&] { const char *q = p; return impl->validate_ascii_with_errors(ESC(q), len).error == simdutf::SUCCESS; });
    else if (func == "utf16le")
      bench(row, len, [&] { const char16_t *q = u16; return impl->validate_utf16le(ESC(q), len / 2); });
    else if (func == "utf16le_with_errors")
      bench(row, len, [&] { const char16_t *q = u16; return impl->validate_utf16le_with_errors(ESC(q), len / 2).error == simdutf::SUCCESS; });
    else if (func == "utf16be")
      bench(row, len, [&] { const char16_t *q = u16; return impl->validate_utf16be(ESC(q), len / 2); });
    else if (func == "utf16be_with_errors")
      bench(row, len, [&] { const char16_t *q = u16; return impl->validate_utf16be_with_errors(ESC(q), len / 2).error == simdutf::SUCCESS; });
    else if (func == "utf32")
      bench(row, len, [&] { const char32_t *q = u32; return impl->validate_utf32(ESC(q), len / 4); });
    else if (func == "utf32_with_errors")
      bench(row, len, [&] { const char32_t *q = u32; return impl->validate_utf32_with_errors(ESC(q), len / 4).error == simdutf::SUCCESS; });
    std::free(base);
  }
}
