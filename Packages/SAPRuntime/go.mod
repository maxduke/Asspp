module github.com/majd/ipatool/v2

go 1.26.5

// go-apfs requires this package path; keep decoding pure Go for cross-platform builds.
replace github.com/blacktop/lzfse-cgo => ./internal/lzfsecompat

require (
	github.com/blacktop/go-apfs v1.0.28
	github.com/blacktop/go-macho v1.1.282
	github.com/bodgit/sevenzip v1.6.3
	github.com/deploymenttheory/go-macos-pkg v0.3.0
	github.com/ebitengine/purego v0.10.2
	github.com/go-compressions/lzfse v0.3.0
	github.com/klauspost/compress v1.18.6
	github.com/onsi/ginkgo/v2 v2.5.0
	github.com/onsi/gomega v1.24.0
	howett.net/plist v1.0.1
)

require (
	github.com/VividCortex/ewma v1.2.0 // indirect
	github.com/acarl005/stripansi v0.0.0-20180116102854-5a71ef0e047d // indirect
	github.com/andybalholm/brotli v1.2.1 // indirect
	github.com/apex/log v1.9.0 // indirect
	github.com/blacktop/go-dwarf v1.0.14 // indirect
	github.com/blacktop/go-plist v1.0.2 // indirect
	github.com/blacktop/lzfse-cgo v1.2.0 // indirect
	github.com/bodgit/plumbing v1.3.0 // indirect
	github.com/bodgit/windows v1.0.1 // indirect
	github.com/dustin/go-humanize v1.1.0 // indirect
	github.com/fatih/color v1.19.0 // indirect
	github.com/go-logr/logr v1.4.3 // indirect
	github.com/golang/protobuf v1.5.4 // indirect
	github.com/google/go-cmp v0.7.0 // indirect
	github.com/hashicorp/golang-lru/v2 v2.0.7 // indirect
	github.com/kr/pretty v0.3.1 // indirect
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.22 // indirect
	github.com/mattn/go-runewidth v0.0.16 // indirect
	github.com/pierrec/lz4/v4 v4.1.29 // indirect
	github.com/pkg/errors v0.9.1 // indirect
	github.com/rivo/uniseg v0.4.7 // indirect
	github.com/rogpeppe/go-internal v1.14.1 // indirect
	github.com/spf13/afero v1.15.0 // indirect
	github.com/stangelandcl/ppmd v0.1.0 // indirect
	github.com/ulikunitz/xz v0.5.17 // indirect
	github.com/vbauerster/mpb/v7 v7.5.3 // indirect
	github.com/xi2/xz v0.0.0-20171230120015-48954b6210f8 // indirect
	go4.org v0.0.0-20260112195520-a5071408f32f // indirect
	golang.org/x/net v0.58.0 // indirect
	golang.org/x/sys v0.48.0 // indirect
	golang.org/x/text v0.42.0 // indirect
	gopkg.in/check.v1 v1.0.0-20201130134442-10cb98267c6c // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)
