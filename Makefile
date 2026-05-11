TALOS_VERSION ?= v1.13.0
ARCH ?= amd64
MONO_CORE_DIR ?= ../mono-core
OUT_DIR ?= _out

.PHONY: build iso metal extension clean sbom

build: iso metal

iso:
	TALOS_VERSION=$(TALOS_VERSION) ARCH=$(ARCH) MONO_CORE_DIR=$(MONO_CORE_DIR) OUT_DIR=$(OUT_DIR) ./scripts/build-iso.sh

metal:
	TALOS_VERSION=$(TALOS_VERSION) ARCH=$(ARCH) MONO_CORE_DIR=$(MONO_CORE_DIR) OUT_DIR=$(OUT_DIR) ./scripts/build-metal.sh

extension:
	TALOS_VERSION=$(TALOS_VERSION) ARCH=$(ARCH) MONO_CORE_DIR=$(MONO_CORE_DIR) OUT_DIR=$(OUT_DIR) ./scripts/build-protocore-extension.sh

sbom: build
	syft packages file:$(OUT_DIR)/monarch-os-talos-$(TALOS_VERSION)-$(ARCH).iso -o spdx-json=$(OUT_DIR)/monarch-os-talos-$(TALOS_VERSION)-$(ARCH).iso.spdx.json
	syft packages file:$(OUT_DIR)/monarch-os-talos-$(TALOS_VERSION)-$(ARCH).raw -o spdx-json=$(OUT_DIR)/monarch-os-talos-$(TALOS_VERSION)-$(ARCH).raw.spdx.json

clean:
	rm -rf _build _out
