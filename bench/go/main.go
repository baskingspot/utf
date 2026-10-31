// Command bench-go is the Go arm of `just bench-compare` (bench/README.md):
// the standard library's unicode/utf8, unicode/utf16, and encoding/base64.
//
// Usage, from the repository root, with the same contract as every arm:
//
//	bench-go bench [OP...]   rows in the Go benchmark format
//	bench-go check [OP...]   one checksum line per row
//	bench-go serve           one row per request line on stdin
//
// OP is a name from bench/ops.tsv, which also gives each operation's row
// name, corpus directory, and output size; none means all. BENCHTIME_MS
// (default 100) is how long each row's timed loop runs; Go's own
// testing.Benchmark sizes it. A serve request is `OP INPUT N`: time the row
// N iterations, or for BENCHTIME_MS when N is 0. Every input starts
// BENCH_IN_OFFSET bytes (default 0) past a page boundary and its output
// BENCH_OUT_OFFSET bytes (default 2048) past another, as in every arm.
//
// The standard library has no UTF-8 validator that reports a position, so
// both validation operations time utf8.Valid. It has no slice-to-slice
// transcoder either: the conversions decode one rune at a time and store
// or append it to a preallocated buffer, which is how a Go program avoids
// allocating.
package main

import (
	"bufio"
	"encoding/base64"
	"flag"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode/utf16"
	"unicode/utf8"
	"unsafe"
)

const corpus = "bench/corpus-gen"

// out is what one call returns, for the checksum: validity, the bytes
// written, or a count.
type out struct {
	kind  byte // 'v', 'l', or 'c'
	value int
}

func valid(v bool) out {
	if v {
		return out{'v', 1}
	}
	return out{'v', 0}
}

type input struct {
	name    string
	bytes   []byte
	units16 []uint16
	units32 []rune
}

type buffers struct {
	b8  []byte
	b16 []uint16
	b32 []rune
}

// op is an operation from bench/ops.tsv.
type op struct {
	arg, row, dir string
	num, den      int
}

func (o op) outLen(n int) int {
	if o.num == 0 {
		return 0
	}
	return n*o.num/o.den + 64
}

type fn func(in *input, dst buffers) out

var strict = base64.StdEncoding.Strict()

// impls maps each operation this arm has to its function. StdEncoding
// rejects a missing pad, so it does part of the strict decode's work in
// base64-decode too; it skips CR and LF, so it decodes MIME's lines.
var impls = map[string]fn{
	"validate-utf8":        validate,
	"validate-utf8-err":    validate,
	"utf8-to-utf16le":      utf8ToUtf16,
	"utf8-to-utf32":        utf8ToUtf32,
	"utf16le-to-utf8":      utf16ToUtf8,
	"utf32-to-utf8":        utf32ToUtf8,
	"count-utf8":           count,
	"base64-encode":        encoder(base64.StdEncoding),
	"base64-encode-url":    encoder(base64.RawURLEncoding),
	"base64-decode":        decoder(base64.StdEncoding),
	"base64-decode-url":    decoder(base64.RawURLEncoding),
	"base64-decode-strict": decoder(strict),
	"base64-decode-mime":   decoder(base64.StdEncoding),
}

func validate(in *input, _ buffers) out {
	return valid(utf8.Valid(in.bytes))
}

func count(in *input, _ buffers) out {
	return out{'c', utf8.RuneCount(in.bytes)}
}

func utf8ToUtf16(in *input, b buffers) out {
	dst := b.b16[:0]
	for s := in.bytes; len(s) > 0; {
		r, size := utf8.DecodeRune(s)
		if r == utf8.RuneError && size == 1 {
			return valid(false)
		}
		dst = utf16.AppendRune(dst, r)
		s = s[size:]
	}
	return out{'l', 2 * len(dst)}
}

func utf8ToUtf32(in *input, b buffers) out {
	dst := b.b32
	n := 0
	for s := in.bytes; len(s) > 0; n++ {
		r, size := utf8.DecodeRune(s)
		if r == utf8.RuneError && size == 1 {
			return valid(false)
		}
		dst[n] = r
		s = s[size:]
	}
	return out{'l', 4 * n}
}

func utf16ToUtf8(in *input, b buffers) out {
	dst := b.b8[:0]
	s := in.units16
	for i := 0; i < len(s); i++ {
		r := rune(s[i])
		if utf16.IsSurrogate(r) {
			if i+1 == len(s) {
				return valid(false)
			}
			r = utf16.DecodeRune(r, rune(s[i+1]))
			if r == utf8.RuneError {
				return valid(false)
			}
			i++
		}
		dst = utf8.AppendRune(dst, r)
	}
	return out{'l', len(dst)}
}

func utf32ToUtf8(in *input, b buffers) out {
	dst := b.b8[:0]
	for _, r := range in.units32 {
		if !utf8.ValidRune(r) {
			return valid(false)
		}
		dst = utf8.AppendRune(dst, r)
	}
	return out{'l', len(dst)}
}

func encoder(e *base64.Encoding) fn {
	return func(in *input, b buffers) out {
		e.Encode(b.b8, in.bytes)
		return out{'l', e.EncodedLen(len(in.bytes))}
	}
}

func decoder(e *base64.Encoding) fn {
	return func(in *input, b buffers) out {
		n, err := e.Decode(b.b8, in.bytes)
		if err != nil {
			return valid(false)
		}
		return out{'l', n}
	}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "bench-go: "+format+"\n", args...)
	os.Exit(1)
}

func readOps() []op {
	text, err := os.ReadFile("bench/ops.tsv")
	if err != nil {
		fail("open bench/ops.tsv: %v (run from the repository root)", err)
	}
	var ops []op
	for _, line := range strings.Split(string(text), "\n") {
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.Split(line, "\t")
		num, den, _ := strings.Cut(f[3], "/")
		if den == "" {
			den = "1"
		}
		o := op{arg: f[0], row: f[1], dir: f[2]}
		o.num, _ = strconv.Atoi(num)
		o.den, _ = strconv.Atoi(den)
		ops = append(ops, o)
	}
	for arg := range impls {
		if !slices.ContainsFunc(ops, func(o op) bool { return o.arg == arg }) {
			fail("operation %s is not in bench/ops.tsv", arg)
		}
	}
	return ops
}

// placed returns n bytes off bytes past a page boundary, in an anonymous
// mapping of their own: zeroed, and resident only once written. Every arm
// places its buffers this way.
func placed(n, off int) []byte {
	size := (off + n + 4096) / 4096 * 4096
	m, err := syscall.Mmap(-1, 0, size, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_PRIVATE|syscall.MAP_ANON)
	if err != nil {
		fail("mmap: %v", err)
	}
	return m[off : off+n : off+n]
}

// mapping returns the whole mapping a buffer from placed lies in.
func mapping(b []byte) []byte {
	off := int(uintptr(unsafe.Pointer(unsafe.SliceData(b))) & 4095)
	size := (off + cap(b) + 4096) / 4096 * 4096
	return unsafe.Slice((*byte)(unsafe.Add(unsafe.Pointer(unsafe.SliceData(b)), -off)), size)
}

// release unmaps a buffer from placed.
func release(b []byte) {
	syscall.Munmap(mapping(b))
}

// writeRest writes every page of b's mapping but b's bytes: a masked load
// whose masked-off lanes reach a page nothing has touched takes a microcode
// assist on every call.
func writeRest(b []byte) {
	m := mapping(b)
	off := int(uintptr(unsafe.Pointer(unsafe.SliceData(b))) & 4095)
	clear(m[:off])
	clear(m[off+len(b):])
}

func offsetEnv(name string, def int) int {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 || n >= 4096 || n%4 != 0 {
		fail("%s must be a multiple of 4 under 4096", name)
	}
	return n
}

var (
	inOffset  = offsetEnv("BENCH_IN_OFFSET", 0)
	outOffset = offsetEnv("BENCH_OUT_OFFSET", 2048)
)

// units views b as code units of type T, in place: the corpus is little
// endian, as this machine is, and the offsets keep them aligned.
func units[T any](b []byte) []T {
	var t T
	n := len(b) / int(unsafe.Sizeof(t))
	if n == 0 {
		return nil
	}
	return unsafe.Slice((*T)(unsafe.Pointer(unsafe.SliceData(b))), n)
}

// load reads every file in bench/corpus-gen/<dir>, smallest first, then by
// name.
func load(dir string) []input {
	path := filepath.Join(corpus, dir)
	entries, err := os.ReadDir(path)
	if err != nil {
		fail("open %s: %v (run `just bench-corpus`)", path, err)
	}
	var inputs []input
	for _, entry := range entries {
		f, err := os.Open(filepath.Join(path, entry.Name()))
		if err != nil {
			fail("read %s: %v", entry.Name(), err)
		}
		info, err := f.Stat()
		if err != nil {
			fail("read %s: %v", entry.Name(), err)
		}
		data := placed(int(info.Size()), inOffset)
		if _, err := io.ReadFull(f, data); err != nil {
			fail("read %s: %v", entry.Name(), err)
		}
		writeRest(data)
		f.Close()
		in := input{name: entry.Name(), bytes: data}
		// Only the UTF-16 and UTF-32 inputs need their code units.
		if strings.Contains(dir, "utf16le") {
			in.units16 = units[uint16](data)
		}
		if strings.Contains(dir, "utf32") {
			in.units32 = units[rune](data)
		}
		inputs = append(inputs, in)
	}
	slices.SortFunc(inputs, func(a, b input) int {
		if len(a.bytes) != len(b.bytes) {
			return len(a.bytes) - len(b.bytes)
		}
		return strings.Compare(a.name, b.name)
	})
	return inputs
}

// output returns an operation's output buffer for an input of n bytes,
// unwritten, as each typed view the operation's function writes.
func output(o op, n int) (buffers, []byte) {
	raw := placed(o.outLen(n), outOffset)
	var b buffers
	switch {
	case strings.HasSuffix(o.arg, "-to-utf16le"):
		b.b16 = units[uint16](raw)
	case strings.HasSuffix(o.arg, "-to-utf32"):
		b.b32 = units[rune](raw)
	default:
		b.b8 = raw
	}
	return b, raw
}

// measure times run on one input, n iterations, or for the benchtime when
// n is 0, and prints the row.
func measure(o op, run fn, in *input, b buffers, n int, benchtime time.Duration) {
	if n > 0 {
		flag.Set("test.benchtime", fmt.Sprintf("%dx", n))
	} else {
		flag.Set("test.benchtime", benchtime.String())
	}
	result := testing.Benchmark(func(tb *testing.B) {
		tb.SetBytes(int64(len(in.bytes)))
		for tb.Loop() {
			sink = run(in, b)
		}
	})
	fmt.Printf("Benchmark%s/%s\t%s\n", o.row, in.name, result.String())
}

// serve answers one row per request line, `OP INPUT N`, until stdin ends.
// The requested operation's inputs and outputs stay loaded until another
// is requested.
func serve(ops []op, benchtime time.Duration) {
	var (
		current = -1
		inputs  []input
		outs    []buffers
		raws    [][]byte
	)
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var arg, name string
		var n int
		if _, err := fmt.Sscan(scanner.Text(), &arg, &name, &n); err != nil {
			fail("bad request: %s", scanner.Text())
		}
		i := slices.IndexFunc(ops, func(o op) bool { return o.arg == arg })
		run, ok := impls[arg]
		if i < 0 || !ok {
			fail("no operation %s", arg)
		}
		if i != current {
			for k := range inputs {
				release(inputs[k].bytes)
				release(raws[k])
			}
			current, inputs, outs, raws = i, load(ops[i].dir), nil, nil
			for _, in := range inputs {
				b, raw := output(ops[i], len(in.bytes))
				clear(mapping(raw))
				outs, raws = append(outs, b), append(raws, raw)
			}
		}
		k := slices.IndexFunc(inputs, func(in input) bool { return in.name == name })
		if k < 0 {
			fail("no input %s for %s", name, arg)
		}
		measure(ops[i], run, &inputs[k], outs[k], n, benchtime)
	}
}

var sink out

func main() {
	testing.Init()
	flag.Parse()
	if flag.NArg() < 1 || (flag.Arg(0) != "bench" && flag.Arg(0) != "check" && flag.Arg(0) != "serve") {
		fmt.Fprintln(os.Stderr, "usage: bench-go bench|check [OP...] | serve")
		os.Exit(2)
	}
	check := flag.Arg(0) == "check"
	ops := readOps()
	benchtime := 100 * time.Millisecond
	if ms := os.Getenv("BENCHTIME_MS"); ms != "" {
		n, err := strconv.Atoi(ms)
		if err != nil {
			fail("BENCHTIME_MS needs a number")
		}
		benchtime = time.Duration(n) * time.Millisecond
	}
	if flag.Arg(0) == "serve" {
		serve(ops, benchtime)
		return
	}
	wanted := flag.Args()[1:]
	for _, w := range wanted {
		if !slices.ContainsFunc(ops, func(o op) bool { return o.arg == w }) {
			fmt.Fprintf(os.Stderr, "bench-go: unknown operation %s\n", w)
			os.Exit(2)
		}
	}

	for _, o := range ops {
		if len(wanted) > 0 && !slices.Contains(wanted, o.arg) {
			continue
		}
		run, ok := impls[o.arg]
		if !ok {
			fmt.Printf("# SKIP Benchmark%s: Go's standard library has no equivalent\n", o.row)
			continue
		}
		for _, in := range load(o.dir) {
			b, raw := output(o, len(in.bytes))
			if check {
				r := run(&in, b)
				switch r.kind {
				case 'v':
					fmt.Printf("%s/%s\tvalid=%t\n", o.row, in.name, r.value == 1)
				case 'c':
					fmt.Printf("%s/%s\tcount=%d\n", o.row, in.name, r.value)
				default:
					// Wide output is hashed as its bytes in memory, little
					// endian here.
					h := fnv.New64a()
					h.Write(raw[:r.value])
					fmt.Printf("%s/%s\tlen=%d fnv=%016x\n", o.row, in.name, r.value, h.Sum64())
				}
			} else {
				// Fault every page in before timing: a masked store that
				// overhangs into a page nothing has written takes a
				// microcode assist on every call.
				clear(mapping(raw))
				measure(o, run, &in, b, 0, benchtime)
			}
			release(in.bytes)
			release(raw)
		}
	}
}
