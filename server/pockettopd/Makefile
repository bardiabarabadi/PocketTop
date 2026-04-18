# pockettopd cross-compile targets. The iOS app bundles both binaries and
# the install script picks one at install time based on `uname -m`.

DIST := dist
LDFLAGS := -s -w
CGO_ENABLED ?= 0

.PHONY: all build-all build-amd64 build-arm64 clean

all: build-all

build-all: build-amd64 build-arm64

build-amd64:
	@mkdir -p $(DIST)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=linux GOARCH=amd64 \
		go build -ldflags="$(LDFLAGS)" -o $(DIST)/pockettopd-linux-amd64 .

build-arm64:
	@mkdir -p $(DIST)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=linux GOARCH=arm64 \
		go build -ldflags="$(LDFLAGS)" -o $(DIST)/pockettopd-linux-arm64 .

clean:
	rm -rf $(DIST)
