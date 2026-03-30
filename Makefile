# =============================================================================
# NEDP JDBC Writer - Makefile
# =============================================================================

# Extract version from build.sbt dynamically
VERSION := $(shell grep 'version :=' build.sbt | head -1 | sed 's/.*"\(.*\)".*/\1/')
SCALA_VERSION := 2.12
PROJECT_NAME := spark-jdbc-writer

# Derived paths - JAR
JAR_NAME := $(PROJECT_NAME)-assembly-$(VERSION).jar
JAR_PATH := target/scala-$(SCALA_VERSION)/$(JAR_NAME)

# Derived paths - Python Wheel
WHL_NAME := spark_jdbcwriter-$(VERSION)-py3-none-any.whl
WHL_PATH := python/dist/$(WHL_NAME)

# Derived paths - Glue Template
TEMPLATE_NAME := jdbc_writer_template_v2.py
TEMPLATE_PATH := glue_artifact/$(TEMPLATE_NAME)

# S3 Configuration
S3_BUCKET_UAT := aws-sg-nedp-uat-mwaa
S3_BUCKET_PROD := aws-sg-nedp-prod-mwaa
S3_JAR_PATH := jars/$(JAR_NAME)
S3_WHL_PATH := whl/$(WHL_NAME)
S3_TEMPLATE_PATH := scripts/$(TEMPLATE_NAME)

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m

.PHONY: all clean compile test assembly build wheel push-uat push-prod push-whl-uat push-whl-prod push-template-uat push-template-prod deploy-uat deploy-prod deploy-all-uat deploy-all-prod sync-uat sync-prod help

# Default target
all: build

# =============================================================================
# Build Targets
# =============================================================================

## clean: Remove build artifacts
clean:
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	sbt clean
	@echo "$(GREEN)✓ Clean complete$(NC)"

## compile: Compile Scala sources
compile:
	@echo "$(YELLOW)Compiling sources...$(NC)"
	sbt compile
	@echo "$(GREEN)✓ Compilation complete$(NC)"

## test: Run unit tests
test:
	@echo "$(YELLOW)Running tests...$(NC)"
	sbt test
	@echo "$(GREEN)✓ Tests complete$(NC)"

## assembly: Build fat JAR with all dependencies
assembly:
	@echo "$(YELLOW)Building assembly JAR (v$(VERSION))...$(NC)"
	sbt assembly
	@echo "$(GREEN)✓ JAR built: $(JAR_PATH)$(NC)"

## build: Clean and build JAR (default)
build: clean assembly
	@echo "$(GREEN)✓ Build complete: $(JAR_PATH)$(NC)"
	@ls -lh $(JAR_PATH)

## build-quick: Build JAR without clean
build-quick: assembly
	@echo "$(GREEN)✓ Quick build complete: $(JAR_PATH)$(NC)"
	@ls -lh $(JAR_PATH)

## wheel: Build Python wheel package
wheel:
	@echo "$(YELLOW)Building Python wheel (v$(VERSION))...$(NC)"
	cd python && rm -rf dist/ build/ *.egg-info && python -m build --wheel
	@echo "$(GREEN)✓ Wheel built: $(WHL_PATH)$(NC)"
	@ls -lh $(WHL_PATH)

# =============================================================================
# Deploy Targets
# =============================================================================

## push-uat: Upload JAR to UAT S3 bucket
push-uat:
	@echo "$(YELLOW)Uploading v$(VERSION) to UAT S3...$(NC)"
	@if [ ! -f "$(JAR_PATH)" ]; then \
		echo "$(RED)Error: JAR not found at $(JAR_PATH)$(NC)"; \
		echo "$(RED)Run 'make build' first.$(NC)"; \
		exit 1; \
	fi
	aws s3 cp $(JAR_PATH) s3://$(S3_BUCKET_UAT)/$(S3_JAR_PATH)
	@echo "$(GREEN)✓ Uploaded to s3://$(S3_BUCKET_UAT)/$(S3_JAR_PATH)$(NC)"

## push-prod: Upload JAR to PROD S3 bucket
push-prod:
	@echo "$(YELLOW)Uploading v$(VERSION) to PROD S3...$(NC)"
	@if [ ! -f "$(JAR_PATH)" ]; then \
		echo "$(RED)Error: JAR not found at $(JAR_PATH)$(NC)"; \
		echo "$(RED)Run 'make build' first.$(NC)"; \
		exit 1; \
	fi
	@echo "$(RED)WARNING: Deploying v$(VERSION) to PRODUCTION!$(NC)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ]
	aws s3 cp $(JAR_PATH) s3://$(S3_BUCKET_PROD)/$(S3_JAR_PATH)
	@echo "$(GREEN)✓ Uploaded to s3://$(S3_BUCKET_PROD)/$(S3_JAR_PATH)$(NC)"

## push-whl-uat: Upload Python wheel to UAT S3 bucket
push-whl-uat:
	@echo "$(YELLOW)Uploading wheel v$(VERSION) to UAT S3...$(NC)"
	@if [ ! -f "$(WHL_PATH)" ]; then \
		echo "$(RED)Error: Wheel not found at $(WHL_PATH)$(NC)"; \
		echo "$(RED)Run 'make wheel' first.$(NC)"; \
		exit 1; \
	fi
	aws s3 cp $(WHL_PATH) s3://$(S3_BUCKET_UAT)/$(S3_WHL_PATH)
	@echo "$(GREEN)✓ Uploaded to s3://$(S3_BUCKET_UAT)/$(S3_WHL_PATH)$(NC)"

## push-whl-prod: Upload Python wheel to PROD S3 bucket
push-whl-prod:
	@echo "$(YELLOW)Uploading wheel v$(VERSION) to PROD S3...$(NC)"
	@if [ ! -f "$(WHL_PATH)" ]; then \
		echo "$(RED)Error: Wheel not found at $(WHL_PATH)$(NC)"; \
		echo "$(RED)Run 'make wheel' first.$(NC)"; \
		exit 1; \
	fi
	@echo "$(RED)WARNING: Deploying wheel v$(VERSION) to PRODUCTION!$(NC)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ]
	aws s3 cp $(WHL_PATH) s3://$(S3_BUCKET_PROD)/$(S3_WHL_PATH)
	@echo "$(GREEN)✓ Uploaded to s3://$(S3_BUCKET_PROD)/$(S3_WHL_PATH)$(NC)"

## push-template-uat: Upload Glue template to UAT S3 bucket
push-template-uat:
	@echo "$(YELLOW)Uploading template to UAT S3...$(NC)"
	@if [ ! -f "$(TEMPLATE_PATH)" ]; then \
		echo "$(RED)Error: Template not found at $(TEMPLATE_PATH)$(NC)"; \
		exit 1; \
	fi
	aws s3 cp $(TEMPLATE_PATH) s3://$(S3_BUCKET_UAT)/$(S3_TEMPLATE_PATH)
	@echo "$(GREEN)✓ Uploaded to s3://$(S3_BUCKET_UAT)/$(S3_TEMPLATE_PATH)$(NC)"

## push-template-prod: Upload Glue template to PROD S3 bucket
push-template-prod:
	@echo "$(YELLOW)Uploading template to PROD S3...$(NC)"
	@if [ ! -f "$(TEMPLATE_PATH)" ]; then \
		echo "$(RED)Error: Template not found at $(TEMPLATE_PATH)$(NC)"; \
		exit 1; \
	fi
	@echo "$(RED)WARNING: Deploying template to PRODUCTION!$(NC)"
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ]
	aws s3 cp $(TEMPLATE_PATH) s3://$(S3_BUCKET_PROD)/$(S3_TEMPLATE_PATH)
	@echo "$(GREEN)✓ Uploaded to s3://$(S3_BUCKET_PROD)/$(S3_TEMPLATE_PATH)$(NC)"

## sync-uat: Sync all artifacts (JAR, wheel, template) to UAT without rebuild
sync-uat: push-uat push-whl-uat push-template-uat
	@echo "$(GREEN)✓ All artifacts synced to UAT$(NC)"

## sync-prod: Sync all artifacts (JAR, wheel, template) to PROD without rebuild
sync-prod: push-prod push-whl-prod push-template-prod
	@echo "$(GREEN)✓ All artifacts synced to PROD$(NC)"

## deploy-uat: Build and deploy to UAT
deploy-uat: build push-uat
	@echo "$(GREEN)✓ v$(VERSION) deployed to UAT$(NC)"

## deploy-prod: Build and deploy to PROD (with confirmation)
deploy-prod: build push-prod
	@echo "$(GREEN)✓ v$(VERSION) deployed to PROD$(NC)"

## deploy-all-uat: Build JAR + wheel and deploy all to UAT
deploy-all-uat: build wheel push-uat push-whl-uat push-template-uat
	@echo "$(GREEN)✓ v$(VERSION) JAR + wheel + template deployed to UAT$(NC)"

## deploy-all-prod: Build JAR + wheel and deploy all to PROD (with confirmation)
deploy-all-prod: build wheel push-prod push-whl-prod push-template-prod
	@echo "$(GREEN)✓ v$(VERSION) JAR + wheel + template deployed to PROD$(NC)"

# =============================================================================
# Utility Targets
# =============================================================================

## verify: Verify JAR contents
verify:
	@echo "$(YELLOW)Verifying JAR contents (v$(VERSION))...$(NC)"
	@if [ ! -f "$(JAR_PATH)" ]; then \
		echo "$(RED)Error: JAR not found. Run 'make build' first.$(NC)"; \
		exit 1; \
	fi
	@echo "Key classes:"
	@jar tf $(JAR_PATH) | grep -E "(JdbcWriter|ErrorLogger|ErrorContext)" | head -20
	@echo ""
	@echo "JAR info:"
	@ls -lh $(JAR_PATH)

## check-s3-uat: Check current JAR in UAT S3
check-s3-uat:
	@echo "$(YELLOW)Checking UAT S3 for $(JAR_NAME)...$(NC)"
	aws s3 ls s3://$(S3_BUCKET_UAT)/jars/ | grep spark-jdbc-writer || echo "No JAR found"

## check-s3-prod: Check current JAR in PROD S3
check-s3-prod:
	@echo "$(YELLOW)Checking PROD S3 for $(JAR_NAME)...$(NC)"
	aws s3 ls s3://$(S3_BUCKET_PROD)/jars/ | grep spark-jdbc-writer || echo "No JAR found"

## version: Show current version
version:
	@echo "Version: $(VERSION)"
	@echo "JAR: $(JAR_NAME)"
	@echo "Path: $(JAR_PATH)"

# =============================================================================
# Help
# =============================================================================

## help: Show this help message
help:
	@echo "NEDP JDBC Writer - Build & Deploy (v$(VERSION))"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Build Targets:"
	@echo "  build        Clean and build JAR (default)"
	@echo "  build-quick  Build JAR without clean"
	@echo "  clean        Remove build artifacts"
	@echo "  compile      Compile sources only"
	@echo "  test         Run unit tests"
	@echo "  assembly     Build fat JAR"
	@echo "  wheel        Build Python wheel package"
	@echo ""
	@echo "Deploy Targets:"
	@echo "  push-uat          Upload JAR to UAT S3"
	@echo "  push-prod         Upload JAR to PROD S3 (with confirmation)"
	@echo "  push-whl-uat      Upload wheel to UAT S3"
	@echo "  push-whl-prod     Upload wheel to PROD S3 (with confirmation)"
	@echo "  push-template-uat Upload template to UAT S3"
	@echo "  push-template-prod Upload template to PROD S3"
	@echo "  sync-uat          Sync JAR + wheel + template to UAT (no rebuild)"
	@echo "  sync-prod         Sync JAR + wheel + template to PROD (no rebuild)"
	@echo "  deploy-uat        Build and deploy JAR to UAT"
	@echo "  deploy-prod       Build and deploy JAR to PROD"
	@echo "  deploy-all-uat    Build and deploy JAR + wheel + template to UAT"
	@echo "  deploy-all-prod   Build and deploy JAR + wheel + template to PROD"
	@echo ""
	@echo "Utility Targets:"
	@echo "  verify       Verify JAR contents"
	@echo "  check-s3-uat Check current JAR in UAT S3"
	@echo "  check-s3-prod Check current JAR in PROD S3"
	@echo "  version      Show current version info"
	@echo "  help         Show this help message"
