// utf-oracle: runs inputs through simdutf and writes back its result, so a
// test or a fuzzer can compare this package's error kinds and positions with
// simdutf's (bench/README.md). `just oracle-build` builds it into
// zig-out/bin/utf-oracle; bench/oracle/Oracle.zig is the Zig client.
//
// It reads every request on stdin to EOF, then writes one response per
// request on stdout, in order. Reading first means a client can write a
// whole batch before it reads, without a deadlock. Integers are little
// endian.
//
//   request:  u8 op, u8 option, u32 length, length bytes of input
//   response: u8 error, u64 count, u32 length, length bytes of output
//
// `error` and `count` are simdutf's `result`: its error_code (SUCCESS is 0,
// OTHER is 11, also sent for a request it cannot run, such as UTF-16 input
// of odd length) and either the error's position in input code units or the
// output code units written. The output is the converted text on success and
// empty otherwise. `op` numbers are in the table below; `option` is used
// only by base64: base64_options in the low nibble and
// last_chunk_handling_options in bits 4 and 5 for decode, base64_options for
// encode.
//
// `utf-oracle --implementation` prints the simdutf kernel in use. simdutf
// honors SIMDUTF_FORCE_IMPLEMENTATION, so `fallback` gives its scalar code.

#include <simdutf.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

enum Op : uint8_t {
  validate_utf8 = 1,
  validate_ascii = 2,
  validate_utf16le = 3,
  validate_utf16be = 4,
  validate_utf32 = 5,
  utf8_to_utf16le = 6,
  utf8_to_utf16be = 7,
  utf8_to_utf32 = 8,
  utf8_to_latin1 = 9,
  utf16le_to_utf8 = 10,
  utf16be_to_utf8 = 11,
  utf16le_to_utf32 = 12,
  utf16be_to_utf32 = 13,
  utf16le_to_latin1 = 14,
  utf16be_to_latin1 = 15,
  utf32_to_utf8 = 16,
  utf32_to_utf16le = 17,
  utf32_to_utf16be = 18,
  utf32_to_latin1 = 19,
  latin1_to_utf8 = 20,
  latin1_to_utf16le = 21,
  latin1_to_utf16be = 22,
  latin1_to_utf32 = 23,
  base64_decode = 24,
  base64_encode = 25,
};

// Input and output code unit sizes, in bytes, per op; 0 marks an unknown op.
struct Shape {
  uint8_t in, out;
};

Shape shape(uint8_t op) {
  switch (op) {
  case validate_utf8:
  case validate_ascii:
    return {1, 0};
  case validate_utf16le:
  case validate_utf16be:
    return {2, 0};
  case validate_utf32:
    return {4, 0};
  case utf8_to_utf16le:
  case utf8_to_utf16be:
  case latin1_to_utf16le:
  case latin1_to_utf16be:
    return {1, 2};
  case utf8_to_utf32:
  case latin1_to_utf32:
    return {1, 4};
  case utf8_to_latin1:
  case latin1_to_utf8:
  case base64_decode:
  case base64_encode:
    return {1, 1};
  case utf16le_to_utf8:
  case utf16be_to_utf8:
  case utf16le_to_latin1:
  case utf16be_to_latin1:
    return {2, 1};
  case utf16le_to_utf32:
  case utf16be_to_utf32:
    return {2, 4};
  case utf32_to_utf8:
  case utf32_to_latin1:
    return {4, 1};
  case utf32_to_utf16le:
  case utf32_to_utf16be:
    return {4, 2};
  default:
    return {0, 0};
  }
}

simdutf::result ok(size_t count) { return {simdutf::SUCCESS, count}; }

simdutf::result run(uint8_t op, uint8_t option, const void *in, size_t n,
                    void *out) {
  auto c8 = static_cast<const char *>(in);
  auto c16 = static_cast<const char16_t *>(in);
  auto c32 = static_cast<const char32_t *>(in);
  auto o8 = static_cast<char *>(out);
  auto o16 = static_cast<char16_t *>(out);
  auto o32 = static_cast<char32_t *>(out);
  using namespace simdutf;
  switch (op) {
  case validate_utf8:
    return validate_utf8_with_errors(c8, n);
  case validate_ascii:
    return validate_ascii_with_errors(c8, n);
  case validate_utf16le:
    return validate_utf16le_with_errors(c16, n);
  case validate_utf16be:
    return validate_utf16be_with_errors(c16, n);
  case validate_utf32:
    return validate_utf32_with_errors(c32, n);
  case utf8_to_utf16le:
    return convert_utf8_to_utf16le_with_errors(c8, n, o16);
  case utf8_to_utf16be:
    return convert_utf8_to_utf16be_with_errors(c8, n, o16);
  case utf8_to_utf32:
    return convert_utf8_to_utf32_with_errors(c8, n, o32);
  case utf8_to_latin1:
    return convert_utf8_to_latin1_with_errors(c8, n, o8);
  case utf16le_to_utf8:
    return convert_utf16le_to_utf8_with_errors(c16, n, o8);
  case utf16be_to_utf8:
    return convert_utf16be_to_utf8_with_errors(c16, n, o8);
  case utf16le_to_utf32:
    return convert_utf16le_to_utf32_with_errors(c16, n, o32);
  case utf16be_to_utf32:
    return convert_utf16be_to_utf32_with_errors(c16, n, o32);
  case utf16le_to_latin1:
    return convert_utf16le_to_latin1_with_errors(c16, n, o8);
  case utf16be_to_latin1:
    return convert_utf16be_to_latin1_with_errors(c16, n, o8);
  case utf32_to_utf8:
    return convert_utf32_to_utf8_with_errors(c32, n, o8);
  case utf32_to_utf16le:
    return convert_utf32_to_utf16le_with_errors(c32, n, o16);
  case utf32_to_utf16be:
    return convert_utf32_to_utf16be_with_errors(c32, n, o16);
  case utf32_to_latin1:
    return convert_utf32_to_latin1_with_errors(c32, n, o8);
  case latin1_to_utf8:
    return ok(convert_latin1_to_utf8(c8, n, o8));
  case latin1_to_utf16le:
    return ok(convert_latin1_to_utf16le(c8, n, o16));
  case latin1_to_utf16be:
    return ok(convert_latin1_to_utf16be(c8, n, o16));
  case latin1_to_utf32:
    return ok(convert_latin1_to_utf32(c8, n, o32));
  case base64_decode:
    return base64_to_binary(
        c8, n, o8, static_cast<base64_options>(option & 0x0f),
        static_cast<last_chunk_handling_options>((option >> 4) & 0x03));
  case base64_encode:
    return ok(binary_to_base64(c8, n, o8, static_cast<base64_options>(option)));
  default:
    return {OTHER, 0};
  }
}

void put(std::vector<char> &out, uint64_t v, int bytes) {
  for (int i = 0; i < bytes; i++)
    out.push_back(static_cast<char>(v >> (8 * i)));
}

uint64_t get(const unsigned char *p, int bytes) {
  uint64_t v = 0;
  for (int i = 0; i < bytes; i++)
    v |= uint64_t(p[i]) << (8 * i);
  return v;
}

} // namespace

int main(int argc, char **argv) {
  if (argc == 2 && std::strcmp(argv[1], "--implementation") == 0) {
    auto name = simdutf::get_active_implementation()->name();
    std::printf("%.*s\n", int(name.size()), name.data());
    return 0;
  }
  if (argc != 1) {
    std::fprintf(stderr, "usage: utf-oracle [--implementation] < requests\n");
    return 2;
  }
  std::vector<unsigned char> requests;
  unsigned char chunk[1 << 16];
  size_t got;
  while ((got = std::fread(chunk, 1, sizeof chunk, stdin)) > 0)
    requests.insert(requests.end(), chunk, chunk + got);

  std::vector<char> responses;
  // Aligned for every code unit type; resized to fit each request.
  std::vector<char32_t> in, out;
  size_t at = 0;
  while (at < requests.size()) {
    if (requests.size() - at < 6) {
      std::fprintf(stderr, "utf-oracle: truncated request header\n");
      return 1;
    }
    uint8_t op = requests[at], option = requests[at + 1];
    size_t len = get(&requests[at + 2], 4);
    at += 6;
    if (requests.size() - at < len) {
      std::fprintf(stderr, "utf-oracle: truncated request body\n");
      return 1;
    }
    Shape s = shape(op);
    simdutf::result r{simdutf::OTHER, 0};
    size_t out_bytes = 0;
    if (s.in != 0 && len % s.in == 0) {
      in.assign(len / 4 + 1, 0);
      std::memcpy(in.data(), requests.data() + at, len);
      // The largest output any op writes is four bytes per input byte
      // (Latin-1 to UTF-32), plus base64's rounding.
      out.assign(len + 16, 0);
      r = run(op, option, in.data(), len / s.in, out.data());
      if (r.error == simdutf::SUCCESS && s.out != 0)
        out_bytes = r.count * s.out;
    }
    at += len;
    put(responses, r.error, 1);
    put(responses, r.count, 8);
    put(responses, out_bytes, 4);
    auto o = reinterpret_cast<const char *>(out.data());
    responses.insert(responses.end(), o, o + out_bytes);
  }
  if (std::fwrite(responses.data(), 1, responses.size(), stdout) !=
      responses.size())
    return 1;
  return std::fflush(stdout) == 0 ? 0 : 1;
}
