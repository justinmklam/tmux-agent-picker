SHELL := bash
SCRIPTS := bin/agent-state bin/agent-hook bin/agent-install bin/agent-pick bin/agent-new bin/tmux-agent-picker agents/agy/hook tests/run.sh tmux-agent-picker.tmux

.PHONY: help test check syntax lint reload

help: ## Show this help
	@printf 'targets:\n'
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) \
		| awk -F':.*## ' '{ printf "  %-10s %s\n", $$1, $$2 }'

test: ## Run the end-to-end harness on a private tmux server
	bash tests/run.sh

check: syntax lint ## Parse-check scripts and run shellcheck when installed

syntax: ## Parse-check shell scripts with bash -n
	bash -n $(SCRIPTS)

lint: ## Lint shell scripts with shellcheck when installed
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SCRIPTS); \
	else \
		printf 'shellcheck not installed, skipping\n'; \
	fi

reload: ## Source ~/.tmux.conf into the running tmux server
	tmux source-file ~/.tmux.conf
