// bench-simdutf: the simdutf arm of `just bench-compare` (bench/README.md),
// simdutf from nixpkgs with its runtime dispatch, which picks the best
// kernel for this CPU (the check output names it on stderr).
//
// Usage, from the repository root, with the same contract as every arm:
//
//   bench-simdutf bench [OP...]   rows in the Go benchmark format
//   bench-simdutf check [OP...]   one checksum line per row
//
// OP is validate-utf8, validate-utf8-err, utf8-to-utf16le, utf16le-to-utf8,
// base64-encode, or base64-decode; none means all. BENCHTIME_MS (default
// 100) is how long each row's timed loop runs, sized the way Go's testing.B
// sizes one.

#include <simdutf.h>

#include <algorithm>
#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

namespace {

// What one call returns, for the checksum: validity, or the bytes written.
struct Out {
  bool valid;
  size_t len; // SIZE_MAX for a validation result
};

constexpr size_t no_len = SIZE_MAX;

Out validity(bool v) { return {v, no_len}; }
Out written(size_t n) { return {true, n}; }

using Fn = Out (*)(const char *in, size_t n, char *out);

// Runs F n times over the input and returns the nanoseconds it took. A
// template, so the loop calls F directly, as the other arms' loops do.
template <Fn F>
uint64_t timed(const char *in, size_t len, char *out, uint64_t n) {
  auto start = std::chrono::steady_clock::now();
  for (uint64_t i = 0; i < n; i++) {
    // The input escapes every iteration, so no call is hoisted out.
    asm volatile("" : : "g"(in) : "memory");
    Out r = F(in, len, out);
    asm volatile("" : : "g"(r.valid), "g"(r.len) : "memory");
  }
  auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - start)
                .count();
  return ns > 0 ? uint64_t(ns) : 1;
}

struct Op {
  const char *arg, *row, *dir;
  size_t (*out_len)(size_t);
  Fn run;
  uint64_t (*timed)(const char *, size_t, char *, uint64_t);
};

Out validate_utf8(const char *in, size_t n, char *) {
  return validity(simdutf::validate_utf8(in, n));
}
Out validate_utf8_err(const char *in, size_t n, char *) {
  return validity(simdutf::validate_utf8_with_errors(in, n).error ==
                  simdutf::SUCCESS);
}
Out utf8_to_utf16le(const char *in, size_t n, char *out) {
  auto r = simdutf::convert_utf8_to_utf16le_with_errors(
      in, n, reinterpret_cast<char16_t *>(out));
  if (r.error != simdutf::SUCCESS)
    return validity(false);
  return written(2 * r.count);
}
Out utf16le_to_utf8(const char *in, size_t n, char *out) {
  auto r = simdutf::convert_utf16le_to_utf8_with_errors(
      reinterpret_cast<const char16_t *>(in), n / 2, out);
  if (r.error != simdutf::SUCCESS)
    return validity(false);
  return written(r.count);
}
Out base64_encode(const char *in, size_t n, char *out) {
  return written(simdutf::binary_to_base64(in, n, out));
}
Out base64_decode(const char *in, size_t n, char *out) {
  auto r = simdutf::base64_to_binary(in, n, out);
  if (r.error != simdutf::SUCCESS)
    return validity(false);
  return written(r.count);
}

const Op ops[] = {
    {"validate-utf8", "ValidateUtf8", "utf8", [](size_t) -> size_t { return 0; },
     validate_utf8, timed<validate_utf8>},
    {"validate-utf8-err", "ValidateUtf8Err", "utf8-err",
     [](size_t) -> size_t { return 0; }, validate_utf8_err, timed<validate_utf8_err>},
    {"utf8-to-utf16le", "Utf8ToUtf16le", "utf8",
     [](size_t n) { return 2 * n + 2; }, utf8_to_utf16le, timed<utf8_to_utf16le>},
    {"utf16le-to-utf8", "Utf16leToUtf8", "utf16le",
     [](size_t n) { return 3 * n + 3; }, utf16le_to_utf8, timed<utf16le_to_utf8>},
    {"base64-encode", "Base64Encode", "binary",
     [](size_t n) { return (n + 2) / 3 * 4; }, base64_encode, timed<base64_encode>},
    {"base64-decode", "Base64Decode", "base64",
     [](size_t n) { return n / 4 * 3 + 3; }, base64_decode, timed<base64_decode>},
};

struct Input {
  std::string name;
  std::vector<char> data;
};

// Every file in bench/corpus-gen/<dir>, smallest first, then by name.
std::vector<Input> load(const char *dir) {
  namespace fs = std::filesystem;
  fs::path path = fs::path("bench/corpus-gen") / dir;
  std::error_code ec;
  fs::directory_iterator it(path, ec);
  if (ec) {
    std::fprintf(stderr, "bench-simdutf: open %s: %s (run `just bench-corpus`)\n",
                 path.c_str(), ec.message().c_str());
    std::exit(1);
  }
  std::vector<Input> inputs;
  for (const auto &entry : it) {
    // Read at the file's size, so the buffer is never grown and copied.
    std::vector<char> data(entry.file_size());
    std::ifstream(entry.path(), std::ios::binary)
        .read(data.data(), std::streamsize(data.size()));
    inputs.push_back({entry.path().filename().string(), std::move(data)});
  }
  std::sort(inputs.begin(), inputs.end(), [](const Input &a, const Input &b) {
    if (a.data.size() != b.data.size())
      return a.data.size() < b.data.size();
    return a.name < b.name;
  });
  return inputs;
}

uint64_t fnv1a(const char *p, size_t n) {
  uint64_t h = 0xcbf29ce484222325ull;
  for (size_t i = 0; i < n; i++)
    h = (h ^ static_cast<unsigned char>(p[i])) * 0x100000001b3ull;
  return h;
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 2 ||
      (std::strcmp(argv[1], "bench") != 0 && std::strcmp(argv[1], "check") != 0)) {
    std::fprintf(stderr, "usage: bench-simdutf bench|check [OP...]\n");
    return 2;
  }
  bool check = std::strcmp(argv[1], "check") == 0;
  std::vector<std::string> wanted(argv + 2, argv + argc);
  for (const auto &w : wanted) {
    if (std::none_of(std::begin(ops), std::end(ops),
                     [&](const Op &op) { return w == op.arg; })) {
      std::fprintf(stderr, "bench-simdutf: unknown operation %s\n", w.c_str());
      return 2;
    }
  }
  uint64_t goal = 100'000'000;
  if (const char *ms = std::getenv("BENCHTIME_MS"))
    goal = std::strtoull(ms, nullptr, 10) * 1'000'000;
  if (check) {
    auto name = simdutf::get_active_implementation()->name();
    std::fprintf(stderr, "bench-simdutf: simdutf %s, kernel %.*s\n",
                 SIMDUTF_VERSION, int(name.size()), name.data());
  }

  for (const Op &op : ops) {
    if (!wanted.empty() &&
        std::find(wanted.begin(), wanted.end(), op.arg) == wanted.end())
      continue;
    for (Input &in : load(op.dir)) {
      // Aligned for any output code unit, and left uninitialized, as the
      // other arms' buffers are, so only the pages written count in RSS.
      std::unique_ptr<char32_t[]> buf(
          new char32_t[op.out_len(in.data.size()) / 4 + 1]);
      char *out = reinterpret_cast<char *>(buf.get());
      const char *data = in.data.data();
      size_t len = in.data.size();
      if (check) {
        Out r = op.run(data, len, out);
        if (r.len == no_len)
          std::printf("%s/%s\tvalid=%s\n", op.row, in.name.c_str(),
                      r.valid ? "true" : "false");
        else
          std::printf("%s/%s\tlen=%zu fnv=%016" PRIx64 "\n", op.row,
                      in.name.c_str(), r.len, fnv1a(out, r.len));
        continue;
      }
      // Go's testing.B loop sizing: grow n until a run takes the goal.
      const uint64_t max_n = 1'000'000'000;
      uint64_t n = 1;
      uint64_t ns = op.timed(data, len, out, n);
      while (ns < goal && n < max_n) {
        uint64_t last = n;
        uint64_t next =
            uint64_t((unsigned __int128)goal * last / ns);
        next += next / 5;
        n = std::min({std::max(next, last + 1), 100 * last, max_n});
        ns = op.timed(data, len, out, n);
      }
      std::printf("Benchmark%s/%s\t%" PRIu64 "\t%.2f ns/op\t%.2f MB/s\n",
                  op.row, in.name.c_str(), n, double(ns) / double(n),
                  double(len) * double(n) * 1e3 / double(ns));
      std::fflush(stdout);
    }
  }
  return 0;
}
