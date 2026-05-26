TALOS_VERSION ?= v1.13.0
ARCH ?= amd64
MONO_CORE_DIR ?= ../mono-core
OUT_DIR ?= _out

.PHONY: build iso metal extension metadata smoke-qemu clean sbom

build: iso metal

iso:
	TALOS_VERSION=$(TALOS_VERSION) ARCH=$(ARCH) MONO_CORE_DIR=$(MONO_CORE_DIR) OUT_DIR=$(OUT_DIR) ./scripts/build-iso.sh

metal:
	TALOS_VERSION=$(TALOS_VERSION) ARCH=$(ARCH) MONO_CORE_DIR=$(MONO_CORE_DIR) OUT_DIR=$(OUT_DIR) ./scripts/build-metal.sh

extension:
	TALOS_VERSION=$(TALOS_VERSION) ARCH=$(ARCH) MONO_CORE_DIR=$(MONO_CORE_DIR) OUT_DIR=$(OUT_DIR) ./scripts/build-protocore-extension.sh

metadata:
	TALOS_VERSION=$(TALOS_VERSION) ARCH=$(ARCH) MONO_CORE_DIR=$(MONO_CORE_DIR) OUT_DIR=$(OUT_DIR) ./scripts/write-release-metadata.sh

smoke-qemu: metal
	TALOS_VERSION=$(TALOS_VERSION) ARCH=$(ARCH) OUT_DIR=$(OUT_DIR) ./scripts/smoke-qemu.sh

sbom:
	@if [ -f "$(OUT_DIR)/monarch-os-talos-$(TALOS_VERSION)-$(ARCH).iso" ]; then \
		syft packages file:$(OUT_DIR)/monarch-os-talos-$(TALOS_VERSION)-$(ARCH).iso -o spdx-json=$(OUT_DIR)/monarch-os-talos-$(TALOS_VERSION)-$(ARCH).iso.spdx.json; \
	fi
	@if [ -f "$(OUT_DIR)/monarch-os-talos-$(TALOS_VERSION)-$(ARCH).raw" ]; then \
		syft packages file:$(OUT_DIR)/monarch-os-talos-$(TALOS_VERSION)-$(ARCH).raw -o spdx-json=$(OUT_DIR)/monarch-os-talos-$(TALOS_VERSION)-$(ARCH).raw.spdx.json; \
	fi

clean:
	rm -rf _build _out
