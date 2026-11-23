SHELL := /usr/bin/env bash
ENV ?= dev
TAG ?= 1.1.0
KUBECONFORM_SCHEMAS := -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

.PHONY: help bootstrap teardown images test validate status refresh demo-help \
        release promote bad-release revert rotate drift traffic watch

help: ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Create cluster + platform, bind Argo CD to this repo
	./bootstrap.sh

teardown: ## Delete the kind cluster (keeps sealing key)
	./teardown.sh

images: ## Rebuild + side-load all demo-app versions
	scripts/build-images.sh

test: ## Go unit tests
	cd app && go vet ./... && go test ./...

validate: ## Render every overlay and schema-check it (incl. CRDs)
	@for e in dev staging prod; do echo "== $$e"; \
	  kustomize build apps/demo-app/overlays/$$e | kubeconform -strict -summary $(KUBECONFORM_SCHEMAS) || exit 1; done
	@kubeconform -strict -summary $(KUBECONFORM_SCHEMAS) platform/apps platform/bootstrap

status: ## Apps, rollouts, live versions
	scripts/demo.sh status

refresh: ## Force Argo CD to re-read Git now
	scripts/demo.sh refresh

demo-help: ## Demo commands
	scripts/demo.sh help

release: ## make release ENV=dev TAG=1.1.0
	scripts/demo.sh release $(ENV) $(TAG)

promote: ## make promote FROM=dev TO=staging
	scripts/demo.sh promote $(FROM) $(TO)

bad-release: ## make bad-release ENV=dev TAG=1.2.0
	scripts/demo.sh bad-release $(ENV) $(TAG)

revert: ## git revert HEAD + push
	scripts/demo.sh revert

rotate: ## make rotate ENV=dev
	scripts/demo.sh rotate $(ENV)

drift: ## make drift ENV=prod
	scripts/demo.sh drift $(ENV)

traffic: ## make traffic ENV=dev
	scripts/demo.sh traffic $(ENV)

watch: ## make watch ENV=dev
	scripts/demo.sh watch $(ENV)
