.PHONY: build test lint docker-build clean

BINARY := bin/cortex-sidecar

build:
	CGO_ENABLED=0 go build -o $(BINARY) ./cmd/cortex-sidecar

test:
	go test ./... -race -v

lint:
	go vet ./...
	@which golangci-lint > /dev/null 2>&1 && golangci-lint run || echo "golangci-lint not installed, skipping"

docker-build:
	docker build -t cortex-sidecar .

clean:
	rm -rf bin/
