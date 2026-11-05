// Interleaved comparison of three UTF-8 to UTF-32 decoders that write
// U+FFFD for each maximal subpart, as Ghostty's terminal input decoder
// needs: simdutf in Ghostty's loop (src/simd/vt.cpp before the switch to
// utf), utf in the same loop (src/simd/vt.zig, shim.zig), and utf's
// `convert.utf8ToUtf32Replacing`, one call. Each round times every row on
// every arm back to back, in an order that rotates by row and round; the
// first pass sizes the loops. Output is Go benchmark format.
//
//   ab test             random inputs through all three, which must agree
//   ab run ROUNDS [FILTER]   BENCH_MS per sample (default 20)
//
// The inputs follow Ghostty's synthetic UTF-8 generator
// (src/synthetic/Utf8.zig): each sequence is malformed with probability
// RATE, then one of Ghostty's nine malformed sequences, else a code point
// of 1-4 bytes with equal weight ("mixed", the generator's default) or
// printable ASCII ("ascii").
#include <simdutf.h>

#include <pthread.h>
#ifdef __APPLE__
#include <sys/qos.h>
#endif

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <random>
#include <string>
#include <vector>

extern "C" size_t loop_decode_utf8(const uint8_t *, size_t, uint32_t *);
extern "C" size_t replacing_decode_utf8(const uint8_t *, size_t, uint32_t *);

// ---- Ghostty's code (src/simd/vt.cpp), verbatim apart from formatting ----
static size_t MaximalSubpart(const unsigned char *p, size_t len) {
  if (len == 0) return 0;
  unsigned char b0 = p[0];
  if (b0 < 0xC2 || b0 > 0xF4) return 1;
  size_t seq_len;
  unsigned char lo[3], hi[3];
  if (b0 <= 0xDF) { seq_len = 2; lo[0] = 0x80; hi[0] = 0xBF; }
  else if (b0 == 0xE0) { seq_len = 3; lo[0] = 0xA0; hi[0] = 0xBF; lo[1] = 0x80; hi[1] = 0xBF; }
  else if (b0 <= 0xEC) { seq_len = 3; lo[0] = 0x80; hi[0] = 0xBF; lo[1] = 0x80; hi[1] = 0xBF; }
  else if (b0 == 0xED) { seq_len = 3; lo[0] = 0x80; hi[0] = 0x9F; lo[1] = 0x80; hi[1] = 0xBF; }
  else if (b0 <= 0xEF) { seq_len = 3; lo[0] = 0x80; hi[0] = 0xBF; lo[1] = 0x80; hi[1] = 0xBF; }
  else if (b0 == 0xF0) { seq_len = 4; lo[0] = 0x90; hi[0] = 0xBF; lo[1] = 0x80; hi[1] = 0xBF; lo[2] = 0x80; hi[2] = 0xBF; }
  else if (b0 <= 0xF3) { seq_len = 4; lo[0] = 0x80; hi[0] = 0xBF; lo[1] = 0x80; hi[1] = 0xBF; lo[2] = 0x80; hi[2] = 0xBF; }
  else { seq_len = 4; lo[0] = 0x80; hi[0] = 0x8F; lo[1] = 0x80; hi[1] = 0xBF; lo[2] = 0x80; hi[2] = 0xBF; }
  size_t valid = 1;
  for (size_t i = 0; i < seq_len - 1 && valid < len; i++) {
    unsigned char cb = p[valid];
    if (cb < lo[i] || cb > hi[i]) break;
    valid++;
  }
  return valid;
}

static size_t simdutf_decode_utf8(const uint8_t *input, size_t count, uint32_t *output) {
  if (count == 0) return 0;
  const char *in = reinterpret_cast<const char *>(input);
  size_t remaining = count;
  char32_t *out = reinterpret_cast<char32_t *>(output);
  while (remaining > 0) {
    auto r = simdutf::convert_utf8_to_utf32_with_errors(in, remaining, out);
    if (r.error == simdutf::SUCCESS) { out += r.count; break; }
    out += simdutf::count_utf8(in, r.count);
    const unsigned char *err_pos = reinterpret_cast<const unsigned char *>(in + r.count);
    size_t skip = r.count + MaximalSubpart(err_pos, remaining - r.count);
    *out++ = 0xFFFD;
    in += skip;
    remaining -= skip;
  }
  return static_cast<size_t>(out - reinterpret_cast<char32_t *>(output));
}
// ---- end Ghostty's code ----

static std::mt19937_64 rng(0x5eed0fffd);
static uint64_t rnd(uint64_t n) { return rng() % n; }
static double unit() { return (rng() >> 11) * (1.0 / 9007199254740992.0); }

static void put_cp(std::string &s, uint32_t cp) {
  if (cp < 0x80) s += char(cp);
  else if (cp < 0x800) { s += char(0xC0 | cp >> 6); s += char(0x80 | (cp & 63)); }
  else if (cp < 0x10000) { s += char(0xE0 | cp >> 12); s += char(0x80 | (cp >> 6 & 63)); s += char(0x80 | (cp & 63)); }
  else { s += char(0xF0 | cp >> 18); s += char(0x80 | (cp >> 12 & 63)); s += char(0x80 | (cp >> 6 & 63)); s += char(0x80 | (cp & 63)); }
}

// Ghostty's invalid_sequences.
static const char *const malformed[] = {
    "\x80", "\xC0", "\xFF", "\xC2\x20", "\xC0\xAF", "\x80\x80", "\xED\xA0\x80", "\xE2\x28\x7A", "\xF0\x90\x28\x7A",
};

// `len` bytes or a few more, from Ghostty's generator: each sequence
// malformed with probability `rate`.
static std::string generate(bool ascii, double rate, size_t len) {
  std::string s;
  while (s.size() < len) {
    if (rate > 0 && unit() < rate) {
      s += malformed[rnd(9)];
      continue;
    }
    if (ascii) {
      s += char(0x20 + rnd(95));
      continue;
    }
    uint32_t cp;
    do {
      switch (rnd(4)) {
        case 0: cp = rnd(0x80); break;
        case 1: cp = 0x80 + rnd(0x780); break;
        case 2: cp = 0x800 + rnd(0xF800); break;
        default: cp = 0x10000 + rnd(0x100000);
      }
    } while (cp >= 0xD800 && cp < 0xE000);
    put_cp(s, cp);
  }
  return s;
}

// simdutf leaves the output before an error unspecified, and its icelake
// kernel writes other code points there, so Ghostty's loop around it
// garbles text near errors on AVX-512: the two utf arms must agree, and
// simdutf's disagreements are counted apart.
static int difftest() {
  int failures = 0, simdutf_differs = 0;
  std::vector<uint32_t> a(70000), b(70000), c(70000);
  const double rates[] = {0, 0.001, 0.01, 0.05, 0.2, 0.6, 1};
  for (int iter = 0; iter < 300000; iter++) {
    size_t len = iter % 10 == 0 ? rnd(5000) : rnd(300);
    std::string s = generate(iter % 3 == 0, rates[iter % 7], len);
    s.resize(len);
    // Sometimes random bytes on top.
    if (iter % 5 == 0)
      for (size_t k = rnd(8); k > 0 && len > 0; k--) s[rnd(len)] = char(rng());
    auto in = reinterpret_cast<const uint8_t *>(s.data());
    size_t na = simdutf_decode_utf8(in, len, a.data());
    size_t nb = loop_decode_utf8(in, len, b.data());
    size_t nc = replacing_decode_utf8(in, len, c.data());
    if (nb != nc || memcmp(b.data(), c.data(), nb * 4) != 0) {
      if (failures++ < 5) {
        size_t i = 0;
        while (i < nb && b[i] == c[i]) i++;
        fprintf(stderr, "mismatch len=%zu loop=%zu replacing=%zu, first at %zu: %x %x\n", len, nb, nc, i, b[i], c[i]);
      }
    }
    if (na != nb || memcmp(a.data(), b.data(), na * 4) != 0) simdutf_differs++;
  }
  printf("300000 random inputs: loop and replacing disagree on %d, simdutf's loop differs from them on %d\n", failures,
         simdutf_differs);
  return failures;
}

using Clock = std::chrono::steady_clock;

// A buffer at the start of a page of its own.
static uint8_t *page_copy(const std::string &s) {
  void *p = nullptr;
  if (posix_memalign(&p, 16384, s.size() + 16384) != 0) abort();
  memset(p, 0, s.size() + 16384);
  memcpy(p, s.data(), s.size());
  return static_cast<uint8_t *>(p);
}

struct Row {
  std::string input;
  // The mean chunk length.
  size_t bytes;
  std::function<size_t()> arm[3];
  size_t iters[3];
  size_t chunks;
};

static const char *arms[3] = {"simdutf", "loop", "replacing"};
static const int NARMS = 3;

int main(int argc, char **argv) {
#ifdef __APPLE__
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
  if (argc > 1 && !strcmp(argv[1], "test")) return difftest() ? 1 : 0;
  int rounds = argc > 2 ? atoi(argv[2]) : 10;
  const char *filter = argc > 3 ? argv[3] : "";
  double sample_ns = (getenv("BENCH_MS") ? atof(getenv("BENCH_MS")) : 20.0) * 1e6;

  const size_t max_len = 1 << 20;
  uint32_t *out32;
  {
    // Output 2 KiB past a page, as the repository's harness places it.
    void *p = nullptr;
    if (posix_memalign(&p, 16384, max_len * 4 + 16384) != 0) abort();
    memset(p, 0, max_len * 4 + 16384);
    out32 = reinterpret_cast<uint32_t *>(static_cast<char *>(p) + 2048);
  }
  // Each row's calls step through the text a chunk at a time, every chunk
  // cut before a character, so no call sees the bytes the call before it
  // saw: on one input over and over, the branch predictor learns where
  // its errors are, and 4 KiB rows ran 1.5-2x as fast as 64 KiB ones.
  std::vector<Row> rows;
  for (bool ascii : {false, true}) {
    for (double rate : {0.0, 0.001, 0.01, 0.05}) {
      std::string text = generate(ascii, rate, max_len + 4);
      const uint8_t *in = page_copy(text);
      for (size_t n : {16, 64, 256, 4096, 65536, 1 << 20}) {
        auto chunks = std::make_shared<std::vector<std::pair<size_t, size_t>>>();
        size_t total = 0;
        for (size_t at = 0; at + n <= max_len; at += n) {
          size_t start = at, end = at + n;
          while (start > 0 && (in[start] & 0xC0) == 0x80) start++;
          while (end > start && (in[end] & 0xC0) == 0x80) end--;
          chunks->push_back({start, end - start});
          total += end - start;
        }
        char name[64];
        snprintf(name, sizeof name, "%s-%g%%-%zu", ascii ? "ascii" : "mixed", rate * 100, n);
        Row r{name, total / chunks->size(), {}, {}};
        auto arm = [=](size_t (*f)(const uint8_t *, size_t, uint32_t *)) {
          auto next = std::make_shared<size_t>(0);
          return std::function<size_t()>([=] {
            auto [at, len] = (*chunks)[*next];
            if (++*next == chunks->size()) *next = 0;
            return f(in + at, len, out32);
          });
        };
        r.arm[0] = arm(simdutf_decode_utf8);
        r.arm[1] = arm(loop_decode_utf8);
        r.arm[2] = arm(replacing_decode_utf8);
        r.chunks = chunks->size();
        rows.push_back(r);
      }
    }
  }
  rows.erase(std::remove_if(rows.begin(), rows.end(),
                            [&](const Row &r) { return strstr((r.input + "$").c_str(), filter) == nullptr; }),
             rows.end());

  printf("# simdutf %s, implementation %s\n", SIMDUTF_VERSION, simdutf::get_active_implementation()->name().data());
  size_t sink = 0;
  // The utf arms must agree on the count and the output (simdutf's is
  // reported where it differs), then each arm's loop is sized to the
  // sample time.
  std::vector<uint32_t> want(max_len);
  for (auto &r : rows) {
    size_t simdutf_differs = 0;
    for (size_t c = 0; c < r.chunks; c++) {
      size_t n = r.arm[1]();
      std::copy(out32, out32 + n, want.begin());
      for (int a : {2, 0}) {
        memset(out32, 0, (n + 64) * 4);
        if (r.arm[a]() != n || !std::equal(out32, out32 + n, want.begin())) {
          if (a == 0) {
            simdutf_differs++;
            continue;
          }
          fprintf(stderr, "%s: chunk %zu: %s disagrees\n", r.input.c_str(), c, arms[a]);
          return 1;
        }
      }
    }
    if (simdutf_differs) printf("# %s: simdutf's output differs on %zu of %zu chunks\n", r.input.c_str(), simdutf_differs, r.chunks);
    for (int a = 0; a < NARMS; a++) {
      size_t k = 1;
      for (;;) {
        auto t0 = Clock::now();
        for (size_t i = 0; i < k; i++) sink += r.arm[a]();
        double ns = std::chrono::duration<double, std::nano>(Clock::now() - t0).count();
        if (ns > sample_ns / 8) {
          r.iters[a] = std::max<size_t>(1, size_t(k * sample_ns / ns));
          break;
        }
        k *= 2;
      }
    }
  }
  for (int round = 0; round < rounds; round++) {
    for (size_t j = 0; j < rows.size(); j++) {
      auto &r = rows[j];
      for (int i = 0; i < NARMS; i++) {
        int a = (round + j + i) % NARMS;
        size_t n = r.iters[a];
        auto t0 = Clock::now();
        for (size_t k = 0; k < n; k++) sink += r.arm[a]();
        double ns = std::chrono::duration<double, std::nano>(Clock::now() - t0).count() / n;
        printf("BenchmarkReplacing/%s/arm=%s %zu %.2f ns/op %.2f MB/s\n", r.input.c_str(), arms[a], n, ns,
               r.bytes / ns * 1000);
      }
    }
    fflush(stdout);
  }
  fprintf(stderr, "sink %zu\n", sink & 1);
  return 0;
}
