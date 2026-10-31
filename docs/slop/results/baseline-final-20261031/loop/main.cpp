// bench-simdutf's timed loop around a call into a shared library that returns at once.
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
extern "C" size_t noop_lib(const char *, size_t);
struct Out { enum Kind { valid, len, count } kind; size_t value; };
using Fn = Out (*)(const char *in, size_t n, char *out);
Out wrap(const char *in, size_t n, char *) { return {Out::count, noop_lib(in, n)}; }
template <Fn F> uint64_t timed(const char *in, size_t len, char *out, uint64_t n) {
  auto start = std::chrono::steady_clock::now();
  for (uint64_t i = 0; i < n; i++) {
    asm volatile("" : : "g"(in) : "memory");
    Out r = F(in, len, out);
    asm volatile("" : : "g"(r.kind), "g"(r.value) : "memory");
  }
  auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - start).count();
  return ns > 0 ? uint64_t(ns) : 1;
}
int main(int argc, char **argv) {
  static char buf[64];
  uint64_t n = 50000000;
  for (int r = 0; r < 5; r++) {
    timed<wrap>(buf, 16, buf, 1);
    uint64_t ns = timed<wrap>(buf, 16, buf, n);
    std::printf("c++ %.3f ns/op\n", double(ns) / double(n));
  }
}
