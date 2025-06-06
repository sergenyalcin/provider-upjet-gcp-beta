
# SPDX-FileCopyrightText: 2025 Upbound Inc. <https://upbound.io>
#
# SPDX-License-Identifier: Apache-2.0

# ====================================================================================
# Setup Project

PROVIDER_NAME := gcp-beta
PROJECT_NAME := provider-$(PROVIDER_NAME)
PROJECT_REPO := github.com/upbound/$(PROJECT_NAME)

export TERRAFORM_VERSION := 1.5.5
export TERRAFORM_PROVIDER_VERSION := 6.2.0
export TERRAFORM_PROVIDER_SOURCE := hashicorp/google-beta
export TERRAFORM_PROVIDER_REPO ?= https://github.com/hashicorp/terraform-provider-google-beta
export TERRAFORM_DOCS_PATH ?= website/docs/r
export PROVIDER_NAME

PLATFORMS ?= linux_amd64 linux_arm64

export PROJECT_NAME := $(PROJECT_NAME)

# -include will silently skip missing files, which allows us
# to load those files with a target in the Makefile. If only
# "include" was used, the make command would fail and refuse
# to run a target until the include commands succeeded.
-include build/makelib/common.mk

# ====================================================================================
# Setup Output

-include build/makelib/output.mk

# ====================================================================================
# Setup Go

# Set a sane default so that the nprocs calculation below is less noisy on the initial
# loading of this file
NPROCS ?= 1

# each of our test suites starts a kube-apiserver and running many test suites in
# parallel can lead to high CPU utilization. by default we reduce the parallelism
# to half the number of CPU cores.
GO_TEST_PARALLEL := $(shell echo $$(( $(NPROCS) / 2 )))

# We need to specify which repos might require login for go commands to authorize
# correctly.
export GOPRIVATE = github.com/upbound/*

GO_REQUIRED_VERSION ?= 1.21
# GOLANGCILINT_VERSION is inherited from build submodule by default.
# Uncomment below if you need to override the version.
# GOLANGCILINT_VERSION ?= 1.54.0

# SUBPACKAGES ?= $(shell find cmd/provider -type d -maxdepth 1 -mindepth 1 | cut -d/ -f3)
SUBPACKAGES ?= monolith
GO_STATIC_PACKAGES ?= $(GO_PROJECT)/cmd/generator ${SUBPACKAGES:%=$(GO_PROJECT)/cmd/provider/%}
GO_LDFLAGS += -X $(GO_PROJECT)/internal/version.Version=$(VERSION)
GO_SUBDIRS += cmd internal apis
GO111MODULE = on

export SUBPACKAGES := $(SUBPACKAGES)

-include build/makelib/golang.mk

# ====================================================================================
# Setup Kubernetes tools

KIND_VERSION = v0.25.0
# dependency for up
UP_VERSION = v0.28.0
UP_CHANNEL = stable
UPTEST_VERSION = v1.1.2
KUSTOMIZE_VERSION = v5.3.0
YQ_VERSION = v4.40.5
CROSSPLANE_VERSION = 1.14.6
CRDDIFF_VERSION = v0.12.1

export UP_VERSION := $(UP_VERSION)
export UP_CHANNEL := $(UP_CHANNEL)

-include build/makelib/k8s_tools.mk

# ====================================================================================
# Setup Images

REGISTRY_ORGS ?= xpkg.upbound.io/upbound
IMAGES = provider-gcp-beta
BATCH_PLATFORMS ?= linux_amd64,linux_arm64
export BATCH_PLATFORMS := $(BATCH_PLATFORMS)

-include build/makelib/imagelight.mk

# ====================================================================================
# Setup XPKG

XPKG_REG_ORGS ?= xpkg.upbound.io/upbound
# NOTE(hasheddan): skip promoting on xpkg.upbound.io as channel tags are
# inferred.
XPKG_REG_ORGS_NO_PROMOTE ?= xpkg.upbound.io/upbound
XPKG_DIR = $(OUTPUT_DIR)/package
XPKG_IGNORE = kustomization.yaml

export XPKG_REG_ORGS := $(XPKG_REG_ORGS)
export XPKG_REG_ORGS_NO_PROMOTE := $(XPKG_REG_ORGS_NO_PROMOTE)
export XPKG_DIR := $(XPKG_DIR)
export XPKG_IGNORE := $(XPKG_IGNORE)

-include build/makelib/xpkg.mk

# ====================================================================================
# Targets

# run `make help` to see the targets and options

# We want submodules to be set up the first time `make` is run.
# We manage the build/ folder and its Makefiles as a submodule.
# The first time `make` is run, the includes of build/*.mk files will
# all fail, and this target will be run. The next time, the default as defined
# by the includes will be run instead.
fallthrough: submodules
	@echo Initial setup complete. Running make again . . .
	@make

# Generate a coverage report for cobertura applying exclusions on
# - generated file
cobertura:
	@cat $(GO_TEST_OUTPUT)/coverage.txt | \
		grep -v zz_ | \
		$(GOCOVER_COBERTURA) > $(GO_TEST_OUTPUT)/cobertura-coverage.xml

# Update the submodules, such as the common build scripts.
submodules:
	@git submodule sync
	@git submodule update --init --recursive

# This is for running out-of-cluster locally, and is for convenience. Running
# this make target will print out the command which was used. For more control,
# try running the binary directly with different arguments.
run: go.build
	@$(INFO) Running Crossplane locally out-of-cluster . . .
	@# To see other arguments that can be provided, run the command with --help instead
	UPBOUND_CONTEXT="local" $(GO_OUT_DIR)/monolith --debug --certs-dir=""

# NOTE(hasheddan): we ensure up is installed prior to running platform-specific
# build steps in parallel to avoid encountering an installation race condition.
build.init: $(UP)

# ====================================================================================
# Setup Terraform for fetching provider schema
TERRAFORM := $(TOOLS_HOST_DIR)/terraform-$(TERRAFORM_VERSION)
TERRAFORM_WORKDIR := $(WORK_DIR)/terraform
TERRAFORM_PROVIDER_SCHEMA := config/schema.json

$(TERRAFORM):
	@$(INFO) installing terraform $(HOSTOS)-$(HOSTARCH)
	@mkdir -p $(TOOLS_HOST_DIR)/tmp-terraform
	@curl -fsSL https://github.com/upbound/terraform/releases/download/v$(TERRAFORM_VERSION)/terraform_$(TERRAFORM_VERSION)_$(SAFEHOST_PLATFORM).zip -o $(TOOLS_HOST_DIR)/tmp-terraform/terraform.zip
	@unzip $(TOOLS_HOST_DIR)/tmp-terraform/terraform.zip -d $(TOOLS_HOST_DIR)/tmp-terraform
	@mv $(TOOLS_HOST_DIR)/tmp-terraform/terraform $(TERRAFORM)
	@rm -fr $(TOOLS_HOST_DIR)/tmp-terraform
	@$(OK) installing terraform $(HOSTOS)-$(HOSTARCH)

$(TERRAFORM_PROVIDER_SCHEMA): $(TERRAFORM)
	@$(INFO) generating provider schema for $(TERRAFORM_PROVIDER_SOURCE) $(TERRAFORM_PROVIDER_VERSION)
	@mkdir -p $(TERRAFORM_WORKDIR)
	@echo '{"terraform":[{"required_providers":[{"provider":{"source":"'"$(TERRAFORM_PROVIDER_SOURCE)"'","version":"'"$(TERRAFORM_PROVIDER_VERSION)"'"}}],"required_version":"'"$(TERRAFORM_VERSION)"'"}]}' > $(TERRAFORM_WORKDIR)/main.tf.json
	@$(TERRAFORM) -chdir=$(TERRAFORM_WORKDIR) init -upgrade > $(TERRAFORM_WORKDIR)/terraform-logs.txt 2>&1
	@$(TERRAFORM) -chdir=$(TERRAFORM_WORKDIR) providers schema -json=true > $(TERRAFORM_PROVIDER_SCHEMA) 2>> $(TERRAFORM_WORKDIR)/terraform-logs.txt
	@$(OK) generating provider schema for $(TERRAFORM_PROVIDER_SOURCE) $(TERRAFORM_PROVIDER_VERSION)

pull-docs:
	rm -fR "$(WORK_DIR)/$(notdir $(TERRAFORM_PROVIDER_REPO))"
	git clone -c advice.detachedHead=false --depth 1 --filter=blob:none --branch "v$(TERRAFORM_PROVIDER_VERSION)" --sparse "$(TERRAFORM_PROVIDER_REPO)" "$(WORK_DIR)/$(notdir $(TERRAFORM_PROVIDER_REPO))";
	@git -C "$(WORK_DIR)/$(notdir $(TERRAFORM_PROVIDER_REPO))" sparse-checkout set "$(TERRAFORM_DOCS_PATH)"
	@# workaround for being unable override raw registry data. To be tracked in upjet.
	@mv .work/terraform-provider-google-beta/website/docs/r/network_management_connectivity_test_resource.html.markdown .work/terraform-provider-google-beta/website/docs/r/network_management_connectivity_test.html.markdown

generate.init: $(TERRAFORM_PROVIDER_SCHEMA) pull-docs

.PHONY: pull-docs

# ====================================================================================
# End to End Testing
CROSSPLANE_NAMESPACE = upbound-system
-include build/makelib/local.xpkg.mk
-include build/makelib/controlplane.mk

# This target requires the following environment variables to be set:
# - UPTEST_EXAMPLE_LIST, a comma-separated list of examples to test
# - UPTEST_CLOUD_CREDENTIALS (optional), cloud credentials for the provider being tested, e.g. export UPTEST_CLOUD_CREDENTIALS=$(cat ~/gcp-sa.json)
# - UPTEST_DATASOURCE_PATH (optional), see https://github.com/upbound/uptest#injecting-dynamic-values-and-datasource
uptest: $(UPTEST) $(KUBECTL) $(CHAINSAW) $(CROSSPLANE_CLI)
	@$(INFO) running automated tests
	@KUBECTL=$(KUBECTL) CHAINSAW=$(CHAINSAW) CROSSPLANE_CLI=$(CROSSPLANE_CLI) CROSSPLANE_NAMESPACE=$(CROSSPLANE_NAMESPACE) $(UPTEST) e2e "${UPTEST_EXAMPLE_LIST}" --data-source="${UPTEST_DATASOURCE_PATH}" --setup-script=cluster/test/setup.sh --default-conditions="Test" || $(FAIL)
	@$(OK) running automated tests

uptest-local:
	@$(WARN) "this target is deprecated, please use 'make uptest' instead"

build-provider.%:
	@$(MAKE) build SUBPACKAGES="$$(tr ',' ' ' <<< $*)" LOAD_PACKAGES=true

XPKG_SKIP_DEP_RESOLUTION := true

local-deploy.%: controlplane.up
	@for api in $$(tr ',' ' ' <<< $*); do \
		$(MAKE) local.xpkg.deploy.provider.$(PROJECT_NAME)-$${api}; \
		$(INFO) running locally built $(PROJECT_NAME)-$${api}; \
		$(KUBECTL) wait provider.pkg $(PROJECT_NAME)-$${api} --for condition=Healthy --timeout 5m; \
		$(KUBECTL) -n upbound-system wait --for=condition=Available deployment --all --timeout=5m; \
		$(OK) running locally built $(PROJECT_NAME)-$${api}; \
	done || $(FAIL)

local-deploy: build-provider.monolith local-deploy.monolith

# This target requires the following environment variables to be set:
# - UPTEST_CLOUD_CREDENTIALS, cloud credentials for the provider being tested, e.g. export UPTEST_CLOUD_CREDENTIALS=$(cat ~/gcp-sa.json)
# - UPTEST_EXAMPLE_LIST, a comma-separated list of examples to test
# - UPTEST_DATASOURCE_PATH, see https://github.com/upbound/uptest#injecting-dynamic-values-and-datasource
family-e2e:
	@$(INFO) Removing everything under $(XPKG_OUTPUT_DIR) and $(OUTPUT_DIR)/cache...
	@rm -fR $(XPKG_OUTPUT_DIR)
	@rm -fR $(OUTPUT_DIR)/cache
	@(INSTALL_APIS=""; \
	for m in $$(tr ',' ' ' <<< $${UPTEST_EXAMPLE_LIST}); do \
	  	$(INFO) Processing the example manifest "$${m}"; \
		for api in $$(sed -nE 's/^apiVersion: *(.+)/\1/p' "$${m}" | cut -d. -f1); do \
		    if [[ $${api} == "v1" ]]; then \
		        $(INFO) v1 is not a valid provider. Skipping...; \
		        continue; \
		    fi; \
			if [[ $${INSTALL_APIS} =~ " $${api} " ]]; then \
				$(INFO) Resource provider $(PROJECT_NAME)-$${api} is already installed. Skipping...; \
				continue; \
			fi; \
			$(INFO) Installing the family resource $(PROJECT_NAME)-$${api} for the test file: $${m}; \
			INSTALL_APIS="$${INSTALL_APIS} $${api} "; \
		done; \
	done; \
	INSTALL_APIS="config,$$(tr ' ' ',' <<< $${INSTALL_APIS})"; \
	INSTALL_APIS="$$(tr -s ',' <<< "$${INSTALL_APIS}")"; \
	$(INFO) Building and deploying resource providers for the short API groups: $${INSTALL_APIS}; \
	$(MAKE) build-provider.$${INSTALL_APIS} local-deploy.$${INSTALL_APIS}) || $(FAIL)
	$(MAKE) uptest

e2e: family-e2e

# TODO: please move this to the common build submodule
# once the use cases mature
crddiff:
	@$(INFO) Checking breaking CRD schema changes
	@for crd in $${MODIFIED_CRD_LIST}; do \
		if ! git cat-file -e "$${GITHUB_BASE_REF}:$${crd}" 2>/dev/null; then \
			echo "CRD $${crd} does not exist in the $${GITHUB_BASE_REF} branch. Skipping..." ; \
			continue ; \
		fi ; \
		echo "Checking $${crd} for breaking API changes..." ; \
		changes_detected=$$(go run github.com/upbound/uptest/cmd/crddiff@$(CRDDIFF_VERSION) revision --enable-upjet-extensions <(git cat-file -p "$${GITHUB_BASE_REF}:$${crd}") "$${crd}" 2>&1) ; \
		if [[ $$? != 0 ]] ; then \
			printf "\033[31m"; echo "Breaking change detected!"; printf "\033[0m" ; \
			echo "$${changes_detected}" ; \
			echo ; \
		fi ; \
	done
	@$(OK) Checking breaking CRD schema changes

schema-version-diff:
	@$(INFO) Checking for native state schema version changes
	@export PREV_PROVIDER_VERSION=$$(git cat-file -p "${GITHUB_BASE_REF}:Makefile" | sed -nr 's/^export[[:space:]]*TERRAFORM_PROVIDER_VERSION[[:space:]]*:=[[:space:]]*(.+)/\1/p'); \
	echo Detected previous Terraform provider version: $${PREV_PROVIDER_VERSION}; \
	echo Current Terraform provider version: $${TERRAFORM_PROVIDER_VERSION}; \
	mkdir -p $(WORK_DIR); \
	git cat-file -p "$${GITHUB_BASE_REF}:config/schema.json" > "$(WORK_DIR)/schema.json.$${PREV_PROVIDER_VERSION}"; \
	./scripts/version_diff.py config/generated.lst "$(WORK_DIR)/schema.json.$${PREV_PROVIDER_VERSION}" config/schema.json
	@$(OK) Checking for native state schema version changes

.PHONY: uptest e2e crddiff schema-version-diff

# ====================================================================================
# Special Targets

define CROSSPLANE_MAKE_HELP
Crossplane Targets:
    cobertura             Generate a coverage report for cobertura applying exclusions on generated files.
    submodules            Update the submodules, such as the common build scripts.
    run                   Run crossplane locally, out-of-cluster. Useful for development.

endef
# The reason CROSSPLANE_MAKE_HELP is used instead of CROSSPLANE_HELP is because the crossplane
# binary will try to use CROSSPLANE_HELP if it is set, and this is for something different.
export CROSSPLANE_MAKE_HELP

crossplane.help:
	@echo "$$CROSSPLANE_MAKE_HELP"

help-special: crossplane.help

# NOTE(hasheddan): the build submodule currently overrides XDG_CACHE_HOME in
# order to force the Helm 3 to use the .work/helm directory. This causes Go on
# Linux machines to use that directory as the build cache as well. We should
# adjust this behavior in the build submodule because it is also causing Linux
# users to duplicate their build cache, but for now we just make it easier to
# identify its location in CI so that we cache between builds.
go.cachedir:
	@go env GOCACHE

go.mod.cachedir:
	@go env GOMODCACHE

go.lint.analysiskey-interval:
	@# cache is invalidated at least every 7 days
	@echo -n golangci-lint.cache-$$(( $$(date +%s) / (7 * 86400) ))-

go.lint.analysiskey:
	@echo $$(make go.lint.analysiskey-interval)$$(sha1sum go.sum | cut -d' ' -f1)

DEP_CONSTRAINT ?= >= 0.0.0
ifeq (-,$(findstring -,$(VERSION)))
    DEP_CONSTRAINT = >= 0.0.0-0
endif

# use PROVIDERS in place of SUBPACKAGES if set
SUBPACKAGES := $(if $(PROVIDERS),$(PROVIDERS),$(SUBPACKAGES))
# use REPO in place of XPKG_REG_ORGS if set
XPKG_REG_ORGS := $(if $(REPO),$(REPO),$(XPKG_REG_ORGS))
load-pkg: $(UP) build.all
	@$(INFO) Loading the family providers into the Docker daemon: $(SUBPACKAGES)
	@for p in $(PLATFORMS); do \
		mkdir -p "$(XPKG_OUTPUT_DIR)/$$p"; \
	done
	@$(UP) xpkg batch --smaller-providers $$(echo -n "$(SUBPACKAGES) config" | tr ' ' ',') \
		--family-base-image $(BUILD_REGISTRY)/$(PROJECT_NAME) \
		--platform $(BATCH_PLATFORMS) \
		--provider-name $(PROJECT_NAME) \
		--family-package-url-format $(XPKG_REG_ORGS)/%s:$(VERSION) \
		--package-repo-override monolith=$(PROJECT_NAME) --package-repo-override config=provider-family-$(PROVIDER_NAME) \
		--provider-bin-root $(OUTPUT_DIR)/bin \
		--output-dir $(XPKG_OUTPUT_DIR) \
		--store-packages $$(echo -n "$(SUBPACKAGES) config" | tr ' ' ',') \
		--build-only=true \
		--examples-root $(ROOT_DIR)/examples \
		--examples-group-override monolith=* --examples-group-override config=providerconfig \
		--auth-ext $(ROOT_DIR)/package/auth.yaml \
		--crd-root $(ROOT_DIR)/package/crds \
		--crd-group-override monolith=* --crd-group-override config=$(PROVIDER_NAME) \
		--package-metadata-template $(ROOT_DIR)/package/crossplane.yaml.tmpl \
		--template-var XpkgRegOrg=$(XPKG_REG_ORGS) --template-var DepConstraint="$(DEP_CONSTRAINT)" --template-var ProviderName=$(PROVIDER_NAME) \
		--push-retry 10 || $(FAIL)

	@for p in $(PLATFORMS); do \
		docker tag $$(docker load -qi $(XPKG_OUTPUT_DIR)/$$p/$(PROJECT_NAME)-config-$(VERSION).xpkg | awk -F: '{print $$3}') $(XPKG_REG_ORGS)/provider-family-$(PROVIDER_NAME)-$${p#"linux_"}:$(VERSION); \
		echo Loaded the provider package "provider-family-$(PROVIDER_NAME)-$${p#"linux_"}:$(VERSION)" into the Docker daemon; \
		for s in $(SUBPACKAGES); do \
			if [ "$$s" = "config" ]; then \
				continue; \
			fi; \
			docker tag $$(docker load -qi $(XPKG_OUTPUT_DIR)/$$p/$(PROJECT_NAME)-$$s-$(VERSION).xpkg | awk -F: '{print $$3}') $(XPKG_REG_ORGS)/$(PROJECT_NAME)-$$s-$${p#"linux_"}:$(VERSION); \
			echo Loaded the provider package "$(PROJECT_NAME)-$$s-$${p#"linux_"}:$(VERSION)" into the Docker daemon; \
		done \
	done

	@$(OK) Loaded the family providers into the Docker daemon: $(SUBPACKAGES)

.PHONY: cobertura reviewable submodules fallthrough go.mod.cachedir go.cachedir go.lint.analysiskey-interval go.lint.analysiskey run crds.clean $(TERRAFORM_PROVIDER_SCHEMA) load-pkg

build.init: kustomize-crds

kustomize-crds: output.init $(KUSTOMIZE) $(YQ)
	@$(INFO) Kustomizing CRDs...
	@rm -fr $(OUTPUT_DIR)/package || $(FAIL)
	@cp -R package $(OUTPUT_DIR) && \
	cd $(OUTPUT_DIR)/package/crds && \
	$(KUSTOMIZE) create --autodetect || $(FAIL)
	@export YQ=$(YQ) && \
	XDG_CONFIG_HOME=$(PWD)/package $(KUSTOMIZE) build --enable-alpha-plugins $(OUTPUT_DIR)/package/kustomize -o $(OUTPUT_DIR)/package/crds.yaml || $(FAIL)
	@$(OK) Kustomizing CRDs.

.PHONY: kustomize-crds

# TODO(negz): Update CI to use these targets.
vendor: modules.download
vendor.check: modules.check
